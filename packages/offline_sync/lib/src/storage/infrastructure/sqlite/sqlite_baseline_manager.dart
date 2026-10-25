import 'dart:convert';
import 'dart:typed_data';
import 'package:sqlite_async/sqlite_async.dart';
import '../../domain/validation/sync_validator.dart';

/// SQLite helper for pre-mutation baseline snapshots, rollback, and undoable delete restoration.
class SqliteBaselineManager {
  static Future<({String? snapshot, int version})> readExistingBaseline(
    SqliteWriteContext tx,
    String entity,
    String id,
  ) async {
    final existingRows = await tx.getAll('SELECT * FROM "$entity" WHERE "id" = ?', [id]);
    if (existingRows.isEmpty) {
      return (snapshot: null, version: 1);
    }
    final row = existingRows.first;
    var baseSnapshotJson = (row['data_json'] as String?) ?? (row['_base_snapshot_json'] as String?);
    if (baseSnapshotJson == null || baseSnapshotJson == '{}') {
      final rowMap = Map<String, dynamic>.from(row);
      rowMap.remove('_base_snapshot_json');
      rowMap.remove('data_json');
      baseSnapshotJson = jsonEncode(rowMap);
    }
    final baseVersion = (row['version'] as int?) ?? 1;
    return (snapshot: baseSnapshotJson, version: baseVersion);
  }

  static Future<void> restoreBaselineRecord(
    SqliteWriteContext tx, {
    required String entity,
    required String id,
    required String baseJson,
  }) async {
    final baseline = jsonDecode(baseJson) as Map<String, dynamic>;
    final cols = <String>['id', 'version', 'updated_at', '_base_snapshot_json', 'data_json'];
    final vals = <dynamic>[id, 1, DateTime.now().millisecondsSinceEpoch, null, baseJson];

    for (final entry in baseline.entries) {
      if (!cols.contains(entry.key)) {
        cols.add(entry.key);
        final v = entry.value;
        if (v is bool) {
          vals.add(v ? 1 : 0);
        } else if (v is Map || (v is List && v is! Uint8List)) {
          vals.add(jsonEncode(v));
        } else {
          vals.add(v);
        }
      }
    }

    final colList = cols.map((c) => '"$c"').join(', ');
    final placeholders = cols.map((_) => '?').join(', ');
    await tx.execute(
      'INSERT OR REPLACE INTO "$entity" ($colList) VALUES ($placeholders)',
      vals,
    );
  }

  static Future<bool> undoDelete(
    SqliteDatabase db, {
    required String entity,
    required String id,
  }) async {
    SyncValidator.validateEntity(entity);
    SyncValidator.validateId(id);

    return await db.writeTransaction<bool>((tx) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final pendingDeletes = await tx.getAll(
        "SELECT mutation_id, base_snapshot_json FROM _sync_outbox WHERE entity_name = ? AND entity_id = ? AND op = 'delete' AND status = 'pending' AND dispatch_after > ?",
        [entity, id, now],
      );

      if (pendingDeletes.isEmpty) return false;

      final mutation = pendingDeletes.first;
      final mutationId = mutation['mutation_id'] as String;
      final baseJson = mutation['base_snapshot_json'] as String?;

      if (baseJson != null) {
        await restoreBaselineRecord(tx, entity: entity, id: id, baseJson: baseJson);
      }

      await tx.execute('DELETE FROM _sync_outbox WHERE mutation_id = ?', [mutationId]);
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
      final rows = await tx.getAll('SELECT * FROM _sync_outbox WHERE mutation_id = ?', [mutationId]);
      if (rows.isEmpty) return;

      final outbox = rows.first;
      final entity = outbox['entity_name'] as String;
      final id = outbox['entity_id'] as String;
      final baseJson = outbox['base_snapshot_json'] as String?;

      if (baseJson == null) {
        await tx.execute('DELETE FROM "$entity" WHERE "id" = ?', [id]);
      } else {
        await restoreBaselineRecord(tx, entity: entity, id: id, baseJson: baseJson);
      }

      await tx.execute(
        'UPDATE _sync_outbox SET status = ?, updated_at = ? WHERE mutation_id = ?',
        [status, DateTime.now().millisecondsSinceEpoch, mutationId],
      );
    });
  }
}
