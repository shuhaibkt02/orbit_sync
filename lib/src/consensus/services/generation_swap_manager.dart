import 'dart:convert';
import 'dart:io';
import '../../storage/sync_storage.dart';
import '../../transport/sync_transport.dart';
import 'pull_change_applier.dart';

/// Manages atomic SQLite table generation swaps for HTTP 410 Gone recovery
/// without losing unpushed local dirty mutations.
class GenerationSwapManager {
  final SyncStorage storage;
  final SyncTransport transport;

  GenerationSwapManager({
    required this.storage,
    required this.transport,
  });

  /// Executes atomic staging table swap and dirty record reapplication.
  Future<bool> resyncGeneration([List<String>? entities]) async {
    final targetEntities = (entities != null && entities.isNotEmpty)
        ? entities
        : (await storage.db.getAll(
            'SELECT name FROM sqlite_master WHERE type="table" AND name NOT LIKE "\\_%" ESCAPE "\\" AND name NOT LIKE "sqlite_%";',
          ))
            .map((r) => r['name'] as String)
            .toList();
    int cursor = 0;
    final allChanges = <Map<String, dynamic>>[];
    int nextCursor = 0;

    while (true) {
      final resp = await transport.pull(
        sinceCursor: cursor,
        limit: 1000,
        snapshot: true,
      );
      if (resp.statusCode != HttpStatus.ok || resp.error != null) return false;

      final bodyJson = jsonDecode(resp.body) as Map<String, dynamic>;
      final changes =
          (bodyJson['changes'] as List).cast<Map<String, dynamic>>();
      allChanges.addAll(changes);
      nextCursor = (bodyJson['next_cursor'] as int?) ?? cursor;

      final hasMore = (bodyJson['has_more'] as bool?) ?? false;
      if (!hasMore || changes.isEmpty) break;
      cursor = nextCursor;
    }

    await storage.db.writeTransaction((tx) async {
      for (final entity in targetEntities) {
        // 1. Create staging table using universal 5-column schema
        await tx.execute('DROP TABLE IF EXISTS "_staging_$entity";');
        await tx.execute('''
          CREATE TABLE IF NOT EXISTS "_staging_$entity" (
            "id" TEXT PRIMARY KEY,
            "version" INTEGER NOT NULL DEFAULT 1 CHECK ("version" >= 1),
            "updated_at" INTEGER NOT NULL,
            "expires_at" INTEGER,
            "data_json" TEXT NOT NULL DEFAULT '{}'
          );
        ''');

        // 2. Populate staging table with latest remote changes
        final entityChanges = allChanges
            .where((c) => c['entity'] == entity && c['_deleted'] != true);
        for (final change in entityChanges) {
          final id = change['id'].toString();
          final data = (change['data'] as Map<String, dynamic>?) ?? {};
          final version = (change['version'] as int?) ?? 1;
          final now = DateTime.now().millisecondsSinceEpoch;
          final expiresAt =
              (change['expires_at'] as int?) ?? (data['expires_at'] as int?);
          await PullChangeApplier.upsertRow(
              tx, '_staging_$entity', id, data, version, now, expiresAt);
        }

        // 3. Ensure target entity table exists before renaming to avoid "no such table" errors
        await tx.execute('''
          CREATE TABLE IF NOT EXISTS "$entity" (
            "id" TEXT PRIMARY KEY,
            "version" INTEGER NOT NULL DEFAULT 1 CHECK ("version" >= 1),
            "updated_at" INTEGER NOT NULL,
            "expires_at" INTEGER,
            "data_json" TEXT NOT NULL DEFAULT '{}'
          );
        ''');

        // 4. Atomic swap via RENAME
        await tx.execute('DROP TABLE IF EXISTS "_old_$entity";');
        await tx.execute('ALTER TABLE "$entity" RENAME TO "_old_$entity";');
        await tx.execute('ALTER TABLE "_staging_$entity" RENAME TO "$entity";');
        await tx.execute('DROP TABLE IF EXISTS "_old_$entity";');

        // 5. Ensure indexes exist after table rename
        await tx.execute('''
          CREATE INDEX IF NOT EXISTS "idx_${entity}_updated" 
          ON "$entity"(updated_at DESC);
        ''');
        await tx.execute('''
          CREATE INDEX IF NOT EXISTS "idx_${entity}_expires" 
          ON "$entity"(expires_at) 
          WHERE expires_at IS NOT NULL;
        ''');

        // 6. Reapply dirty local pending/in-flight/held outbox mutations on top of fresh table
        final pending = await tx.getAll(
          "SELECT * FROM _sync_outbox WHERE entity_name = ? AND status IN ('pending', 'in_flight', 'held') ORDER BY sequence_id ASC",
          [entity],
        );

        for (final p in pending) {
          final id = p['entity_id'] as String;
          final op = p['op'] as String;
          if (op == 'delete') {
            await tx.execute('DELETE FROM "$entity" WHERE "id" = ?', [id]);
          } else {
            final payload =
                jsonDecode(p['payload_json'] as String) as Map<String, dynamic>;
            final now = DateTime.now().millisecondsSinceEpoch;
            final expiresAt = payload['expires_at'] as int?;
            final payloadVer = (payload['version'] as int?);
            final targetVer =
                payloadVer ?? (((p['base_version'] as int?) ?? 1) + 1);
            await PullChangeApplier.upsertRow(
              tx,
              entity,
              id,
              payload,
              targetVer,
              now,
              expiresAt,
            );
          }
        }
      }

      // 7. Update cursor checkpoint
      await tx.execute(
        'INSERT OR REPLACE INTO _sync_metadata (key, value) VALUES (?, ?)',
        ['last_synced_cursor', nextCursor.toString()],
      );
    });

    return true;
  }
}
