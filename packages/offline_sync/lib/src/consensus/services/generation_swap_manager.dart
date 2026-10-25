import 'dart:convert';
import 'dart:io';
import 'package:sqlite_async/sqlite_async.dart' show SqliteWriteContext;
import '../../storage/sync_storage.dart';
import '../../sync_transport.dart';

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
  Future<bool> resyncGeneration(List<String> entities) async {
    final resp = await transport.pull(
      sinceCursor: 0,
      limit: 1000,
      snapshot: true,
    );
    if (resp.statusCode != HttpStatus.ok || resp.error != null) return false;

    final bodyJson = jsonDecode(resp.body) as Map<String, dynamic>;
    final changes = (bodyJson['changes'] as List).cast<Map<String, dynamic>>();
    final nextCursor = bodyJson['next_cursor'] as int;

    await storage.db.writeTransaction((tx) async {
      for (final entity in entities) {
        // 1. Create staging table with identical schema
        await tx.execute('CREATE TABLE _staging_$entity AS SELECT * FROM "$entity" WHERE 0;');

        // 2. Populate staging table with latest remote changes
        final entityChanges = changes.where((c) => c['entity'] == entity && c['_deleted'] != true);
        for (final change in entityChanges) {
          final id = change['id'].toString();
          final data = (change['data'] as Map<String, dynamic>?) ?? {};
          final version = (change['version'] as int?) ?? 1;
          final now = DateTime.now().millisecondsSinceEpoch;
          await _upsertRow(tx, '_staging_$entity', id, data, version, now, null);
        }

        // 3. Atomic swap via RENAME
        await tx.execute('DROP TABLE IF EXISTS _old_$entity;');
        await tx.execute('ALTER TABLE "$entity" RENAME TO _old_$entity;');
        await tx.execute('ALTER TABLE _staging_$entity RENAME TO "$entity";');
        await tx.execute('DROP TABLE _old_$entity;');

        // 4. Reapply dirty local pending outbox mutations on top of fresh table
        final pending = await tx.getAll(
          "SELECT * FROM _sync_outbox WHERE entity_name = ? AND status = 'pending' ORDER BY created_at ASC",
          [entity],
        );

        for (final p in pending) {
          final id = p['entity_id'] as String;
          final op = p['op'] as String;
          if (op == 'delete') {
            await tx.execute('DELETE FROM "$entity" WHERE "id" = ?', [id]);
          } else {
            final payload = jsonDecode(p['payload_json'] as String) as Map<String, dynamic>;
            final now = DateTime.now().millisecondsSinceEpoch;
            await _upsertRow(
              tx,
              entity,
              id,
              payload,
              (p['base_version'] as int?) ?? 1,
              now,
              p['base_snapshot_json'] as String?,
            );
          }
        }
      }

      // 5. Update cursor checkpoint
      await tx.execute(
        'INSERT OR REPLACE INTO _sync_metadata (key, value) VALUES (?, ?)',
        ['last_synced_cursor', nextCursor.toString()],
      );
    });

    return true;
  }

  static Future<void> _upsertRow(
    SqliteWriteContext tx,
    String entity,
    String id,
    Map<String, dynamic> data,
    int version,
    int now,
    String? baseSnapshot,
  ) async {
    final cols = <String>['id', 'version', 'updated_at', '_base_snapshot_json'];
    final vals = <dynamic>[id, version, now, baseSnapshot];

    for (final entry in data.entries) {
      if (entry.key != 'id' &&
          entry.key != 'version' &&
          entry.key != 'updated_at' &&
          entry.key != '_base_snapshot_json') {
        cols.add('"${entry.key}"');
        vals.add(entry.value);
      }
    }

    final colStr = cols.join(', ');
    final phStr = cols.map((_) => '?').join(', ');
    await tx.execute('INSERT OR REPLACE INTO "$entity" ($colStr) VALUES ($phStr)', vals);
  }
}
