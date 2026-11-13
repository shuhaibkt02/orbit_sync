import 'dart:convert';
import 'package:sqlite_async/sqlite_async.dart';
import '../../domain/validation/sync_validator.dart';

/// SQLite helper for pre-mutation baseline snapshots, rollback, and undoable delete restoration.
class SqliteBaselineManager {
  static Future<({String? snapshot, int version})> readExistingBaseline(
    SqliteWriteContext tx,
    String entity,
    String id,
  ) async {
    final existingRows = await tx
        .getAll('SELECT version, data_json FROM "$entity" WHERE id = ?', [id]);
    if (existingRows.isEmpty) {
      return (snapshot: null, version: 1);
    }
    final row = existingRows.first;
    final baseSnapshotJson = row['data_json'] as String?;
    final baseVersion = (row['version'] as int?) ?? 1;
    return (snapshot: baseSnapshotJson, version: baseVersion);
  }

  static Future<void> restoreBaselineRecord(
    SqliteWriteContext tx, {
    required String entity,
    required String id,
    required String baseJson,
    int? version,
    int? expiresAt,
  }) async {
    int v = version ?? 1;
    int? exp = expiresAt;
    try {
      final decoded = jsonDecode(baseJson);
      if (decoded is Map<String, dynamic>) {
        if (version == null && decoded['version'] is int) {
          v = decoded['version'] as int;
        }
        if (exp == null && decoded['expires_at'] is int) {
          exp = decoded['expires_at'] as int;
        }
      }
    } catch (_) {}

    await tx.execute('''
      INSERT OR REPLACE INTO "$entity" (
        "id", "version", "updated_at", "expires_at", "data_json"
      ) VALUES (?, ?, ?, ?, ?)
    ''', [id, v, DateTime.now().millisecondsSinceEpoch, exp, baseJson]);
  }

  static Future<bool> undoDelete(
    SqliteDatabase db, {
    String? entity,
    required String id,
  }) async {
    if (entity != null) SyncValidator.validateEntity(entity);
    SyncValidator.validateId(id);

    return await db.writeTransaction<bool>((tx) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final pendingDeletes = await tx.getAll(
        entity != null
            ? "SELECT mutation_id, entity_name, base_snapshot_json, base_version FROM _sync_outbox WHERE entity_name = ? AND entity_id = ? AND op = 'delete' AND status = 'pending' AND dispatch_after > ?"
            : "SELECT mutation_id, entity_name, base_snapshot_json, base_version FROM _sync_outbox WHERE entity_id = ? AND op = 'delete' AND status = 'pending' AND dispatch_after > ?",
        entity != null ? [entity, id, now] : [id, now],
      );

      if (pendingDeletes.isEmpty) return false;

      final mutation = pendingDeletes.first;
      final mutationId = mutation['mutation_id'] as String;
      final targetEntity = entity ?? (mutation['entity_name'] as String);
      final baseJson = mutation['base_snapshot_json'] as String?;
      final baseVersion = (mutation['base_version'] as int?) ?? 1;

      if (baseJson != null) {
        await restoreBaselineRecord(
          tx,
          entity: targetEntity,
          id: id,
          baseJson: baseJson,
          version: baseVersion,
        );
      }

      await tx.execute(
          'DELETE FROM _sync_outbox WHERE mutation_id = ?', [mutationId]);
      return true;
    });
  }

  static Future<void> rollbackOptimistic(
    SqliteDatabase db,
    String mutationId, {
    String status = 'conflict',
  }) async {
    SyncValidator.validateStatus(status);

    await db.writeTransaction((tx) async {
      final rows = await tx.getAll(
          'SELECT * FROM _sync_outbox WHERE mutation_id = ?', [mutationId]);
      if (rows.isEmpty) return;

      final outbox = rows.first;
      final entity = outbox['entity_name'] as String;
      final id = outbox['entity_id'] as String;
      final baseJson = outbox['base_snapshot_json'] as String?;

      final baseVersion = (outbox['base_version'] as int?) ?? 1;

      if (baseJson == null) {
        await tx.execute('DELETE FROM "$entity" WHERE "id" = ?', [id]);
      } else {
        await restoreBaselineRecord(
          tx,
          entity: entity,
          id: id,
          baseJson: baseJson,
          version: baseVersion,
        );
      }

      await tx.execute(
        'UPDATE _sync_outbox SET status = ?, updated_at = ? WHERE mutation_id = ?',
        [status, DateTime.now().millisecondsSinceEpoch, mutationId],
      );
    });
  }
}
