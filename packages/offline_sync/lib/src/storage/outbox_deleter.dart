import 'package:sqlite_async/sqlite_async.dart';
import 'uuid_v7.dart';
import 'sync_validator.dart';
import 'baseline_manager.dart';

/// Handles entity deletions, rapid grace window annihilation, and foreign key cascade capture.
class OutboxDeleter {
  /// Atomically marks domain entity deleted and appends delete envelope to outbox.
  /// If an unsynced creation is deleted within its grace window, both rows are annihilated locally (0 network requests).
  static Future<String?> delete({
    required SqliteDatabase db,
    required Set<String> knownColumns,
    required String entity,
    required String id,
    String? endpointUrl,
    String? httpMethod,
    Duration? undoWindow,
  }) async {
    SyncValidator.validateEntity(entity);
    SyncValidator.validateId(id);
    SyncValidator.validateDuration(undoWindow, 'undoWindow');
    SyncValidator.validateHttpMethod(httpMethod);

    return await db.writeTransaction<String?>((tx) async {
      final now = DateTime.now().millisecondsSinceEpoch;

      final tableExists = knownColumns.contains('$entity:id') || (await tx.getAll(
        'SELECT 1 FROM sqlite_master WHERE type="table" AND name = ?',
        [entity],
      )).isNotEmpty;
      if (tableExists) {
        knownColumns.add('$entity:id');
      }

      // 1. Grace Window Annihilation: Check if an unsynced creation is still in hold window
      final pendingCreation = await tx.getAll(
        "SELECT mutation_id FROM _sync_outbox WHERE entity_name = ? AND entity_id = ? AND status = 'pending' AND dispatch_after > ? AND base_snapshot_json IS NULL",
        [entity, id, now],
      );

      if (pendingCreation.isNotEmpty) {
        // Zero-Network Local Annihilation: Delete local domain row and purge pending outbox mutation
        if (tableExists) {
          await tx.execute('DELETE FROM "$entity" WHERE "id" = ?', [id]);
        }
        await tx.execute(
          "DELETE FROM _sync_outbox WHERE entity_name = ? AND entity_id = ? AND status = 'pending'",
          [entity, id],
        );
        return null;
      }

      // 2. Standard or Undoable Delete
      String? baseSnapshotJson;
      int baseVersion = 1;

      if (tableExists) {
        final baseline = await BaselineManager.readExistingBaseline(tx, entity, id);
        baseSnapshotJson = baseline.snapshot;
        baseVersion = baseline.version;
      }

      // 3. Foreign Key Cascade Capture: Find child tables that reference $entity and stage delete mutations
      final dispatchAfter = undoWindow != null ? now + undoWindow.inMilliseconds : now;
      if (tableExists) {
        try {
          final tables = await tx.getAll(
            'SELECT name FROM sqlite_master WHERE type="table" AND name NOT LIKE "\\_%" ESCAPE "\\" AND name NOT LIKE "sqlite_%";',
          );
          for (final t in tables) {
            final childTable = t['name'] as String;
            if (childTable == entity) continue;
            final fks = await tx.getAll('PRAGMA foreign_key_list("$childTable");');
            for (final fk in fks) {
              if (fk['table'] == entity) {
                final childFkCol = fk['from'] as String;
                final childRows = await tx.getAll(
                  'SELECT id, data_json, _base_snapshot_json FROM "$childTable" WHERE "$childFkCol" = ?;',
                  [id],
                );
                for (final child in childRows) {
                  final childId = child['id'] as String;
                  final childMutationId = UuidV7.generate();
                  final childBase = (child['data_json'] as String?) ?? (child['_base_snapshot_json'] as String?);
                  await tx.execute('''
                    INSERT INTO _sync_outbox (
                      mutation_id, entity_name, entity_id, op, endpoint_url, http_method, payload_json,
                      base_snapshot_json, base_version, status, dispatch_after, created_at, updated_at
                    ) VALUES (?, ?, ?, 'delete', NULL, 'DELETE', NULL, ?, 1, 'pending', ?, ?, ?)
                  ''', [
                    childMutationId,
                    childTable,
                    childId,
                    childBase,
                    dispatchAfter,
                    now,
                    now,
                  ]);
                }
              }
            }
          }
        } catch (_) {}

        await tx.execute('DELETE FROM "$entity" WHERE "id" = ?', [id]);
      }

      final mutationId = UuidV7.generate();

      await tx.execute('''
        INSERT INTO _sync_outbox (
          mutation_id, entity_name, entity_id, op, endpoint_url, http_method, payload_json,
          base_snapshot_json, base_version, status, dispatch_after, created_at, updated_at
        ) VALUES (?, ?, ?, 'delete', ?, ?, NULL, ?, ?, 'pending', ?, ?, ?)
      ''', [
        mutationId,
        entity,
        id,
        endpointUrl,
        httpMethod ?? 'DELETE',
        baseSnapshotJson,
        baseVersion,
        dispatchAfter,
        now,
        now,
      ]);

      return mutationId;
    });
  }
}
