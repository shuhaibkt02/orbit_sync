import 'dart:convert';
import 'package:sqlite_async/sqlite_async.dart';
import '../../domain/validation/sync_validator.dart';
import '../uuid/uuid_v7.dart';
import 'sqlite_baseline_manager.dart';

/// SQLite helper for outbox deletions and rapid annihilation.
class SqliteOutboxDeleter {
  static Future<String?> delete({
    required SqliteDatabase db,
    required Set<String> knownColumns,
    required String entity,
    required String id,
    String? endpointUrl,
    String? httpMethod,
    Duration? undoWindow,
    Duration? coolingTime,
    Duration? holdFor,
    Map<String, String>? headers,
    String? authorId,
    String? userId,
  }) async {
    final effectiveUndo = undoWindow ?? coolingTime ?? holdFor;
    SyncValidator.validateEntity(entity);
    SyncValidator.validateId(id);
    SyncValidator.validateDuration(effectiveUndo, 'undoWindow');
    SyncValidator.validateHttpMethod(httpMethod);

    return await db.writeTransaction<String?>((tx) async {
      final now = DateTime.now().millisecondsSinceEpoch;

      final tableExists = knownColumns.contains('$entity:id') ||
          (await tx.getAll(
            'SELECT 1 FROM sqlite_master WHERE type="table" AND name = ?',
            [entity],
          ))
              .isNotEmpty;
      if (tableExists) {
        knownColumns.add('$entity:id');
      }

      final pendingCreation = await tx.getAll(
        "SELECT mutation_id FROM _sync_outbox WHERE entity_name = ? AND entity_id = ? AND status = 'pending' AND dispatch_after > ? AND base_snapshot_json IS NULL",
        [entity, id, now],
      );

      if (pendingCreation.isNotEmpty) {
        if (tableExists) {
          await tx.execute('DELETE FROM "$entity" WHERE "id" = ?', [id]);
        }
        await tx.execute(
          "DELETE FROM _sync_outbox WHERE entity_name = ? AND entity_id = ? AND status = 'pending'",
          [entity, id],
        );
        return null;
      }

      String? baseSnapshotJson;
      int baseVersion = 1;

      if (tableExists) {
        final baseline =
            await SqliteBaselineManager.readExistingBaseline(tx, entity, id);
        baseSnapshotJson = baseline.snapshot;
        baseVersion = baseline.version;
      }

      final dispatchAfter =
          effectiveUndo != null ? now + effectiveUndo.inMilliseconds : now;
      if (tableExists) {
        try {
          final tables = await tx.getAll(
            'SELECT name FROM sqlite_master WHERE type="table" AND name NOT LIKE "\\_%" ESCAPE "\\" AND name NOT LIKE "sqlite_%";',
          );
          for (final t in tables) {
            final childTable = t['name'] as String;
            if (childTable == entity) continue;
            final fks =
                await tx.getAll('PRAGMA foreign_key_list("$childTable");');
            for (final fk in fks) {
              if (fk['table'] == entity) {
                final childFkCol = fk['from'] as String;
                final childRows = await tx.getAll(
                  'SELECT id, data_json FROM "$childTable" WHERE "$childFkCol" = ?;',
                  [id],
                );
                for (final child in childRows) {
                  final childId = child['id'] as String;
                  final childMutationId = UuidV7.generate();
                  final childBase = child['data_json'] as String?;
                  await tx.execute('''
                    INSERT INTO _sync_outbox (
                      mutation_id, entity_name, entity_id, op, endpoint_url, http_method, payload_json,
                      base_snapshot_json, base_version, status, dispatch_after, created_at, updated_at,
                      priority, sla_seconds, schema_version
                    ) VALUES (?, ?, ?, 'delete', NULL, 'DELETE', NULL, ?, 1, 'pending', ?, ?, ?, 1, 86400, 1)
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
          base_snapshot_json, base_version, status, dispatch_after, created_at, updated_at,
          headers_json, author_id, user_id
        ) VALUES (?, ?, ?, 'delete', ?, ?, NULL, ?, ?, 'pending', ?, ?, ?, ?, ?, ?)
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
        headers != null ? jsonEncode(headers) : null,
        authorId,
        userId,
      ]);

      return mutationId;
    });
  }

  /// Restores a deleted record locally if within its undoWindow / cooling window.
  static Future<bool> undoDelete(
    SqliteDatabase db, {
    String? entity,
    required String id,
  }) =>
      SqliteBaselineManager.undoDelete(db, entity: entity, id: id);
}
