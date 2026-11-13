import 'dart:convert';
import 'package:sqlite_async/sqlite_async.dart' show SqliteWriteContext;
import '../../sync_profile.dart';
import 'conflict_reconciler.dart';

/// Applies remote changelog entries into SQLite with tombstone handling and 3-way merges.
class PullChangeApplier {
  final SyncProfile profile;
  final ConflictReconciler reconciler;

  PullChangeApplier({
    required this.profile,
    required this.reconciler,
  });

  /// Processes a single remote change item inside a write transaction.
  Future<void> processChange(SqliteWriteContext tx, Map<String, dynamic> change) async {
    final entity = change['entity'] as String;
    final id = change['id'].toString();
    final isDeleted = change['_deleted'] == true;
    final isLeftScope = change['left_scope'] == true;

    if (isDeleted || isLeftScope) {
      await tx.execute('DELETE FROM "$entity" WHERE "id" = ?', [id]);
      final pendingRows = await tx.getAll(
        "SELECT * FROM _sync_outbox WHERE entity_name = ? AND entity_id = ? AND status IN ('pending', 'in_flight', 'held')",
        [entity, id],
      );
      if (pendingRows.isNotEmpty) {
        await tx.execute('''
          UPDATE _sync_outbox 
          SET status = 'conflict', error_details_json = ? 
          WHERE entity_name = ? AND entity_id = ? AND status IN ('pending', 'in_flight', 'held')
        ''', [
          jsonEncode({
            'type': 'https://orbit-sync.dev/errors/delete-conflict',
            'title': 'Update vs Delete Conflict',
            'detail': 'Record was deleted on the server while modified offline locally.',
          }),
          entity,
          id,
        ]);
      }
      return;
    }

    final remoteData = (change['data'] as Map<String, dynamic>?) ?? {};
    final version = (change['version'] as int?) ?? 1;
    final now = DateTime.now().millisecondsSinceEpoch;
    final expiresAt = (change['expires_at'] as int?) ?? (remoteData['expires_at'] as int?);

    final pendingRows = await tx.getAll(
      "SELECT * FROM _sync_outbox WHERE entity_name = ? AND entity_id = ? AND status IN ('pending', 'in_flight', 'held') ORDER BY created_at ASC",
      [entity, id],
    );

    if (pendingRows.isEmpty) {
      await upsertRow(tx, entity, id, remoteData, version, now, expiresAt);
    } else if (pendingRows.first['op'] == 'delete') {
      if (profile != SyncProfile.basic) {
        await tx.execute('''
          UPDATE _sync_outbox SET status = 'conflict', error_details_json = ? WHERE mutation_id = ?
        ''', [
          jsonEncode({
            'type': 'https://orbit-sync.dev/errors/delete-vs-update',
            'title': 'Delete vs Update Conflict',
            'detail': 'Record was deleted locally while modified remotely on the server.',
          }),
          pendingRows.first['mutation_id'],
        ]);
      }
    } else if (profile == SyncProfile.basic) {
      await upsertRow(tx, entity, id, remoteData, version, now, expiresAt);
      await tx.execute('''
        UPDATE _sync_outbox SET status = 'conflict', error_details_json = ? 
        WHERE entity_name = ? AND entity_id = ? AND status IN ('pending', 'in_flight', 'held')
      ''', [jsonEncode({'title': 'Overwritten by LWW remote change'}), entity, id]);
    } else {
      final pendingMut = pendingRows.first;
      final mutId = pendingMut['mutation_id'] as String;
      final baseJson = pendingMut['base_snapshot_json'] as String?;
      final baseMap = baseJson != null ? (jsonDecode(baseJson) as Map<String, dynamic>) : null;
      final localJson = pendingMut['payload_json'] as String?;
      final localMap = localJson != null ? (jsonDecode(localJson) as Map<String, dynamic>) : <String, dynamic>{};

      final result = reconciler.reconcile(
        entity: entity,
        baseSnapshot: baseMap,
        localRecord: localMap,
        remoteRecord: remoteData,
      );

      if (result.invariantError != null) {
        await tx.execute(
          'UPDATE _sync_outbox SET status = \'conflict\', error_details_json = ? WHERE mutation_id = ?',
          [result.invariantError, mutId],
        );
      } else if (result.merged != null) {
        await upsertRow(tx, entity, id, result.merged!, version, now, expiresAt);
        await tx.execute('''
          UPDATE _sync_outbox 
          SET payload_json = ?, base_snapshot_json = ?, base_version = ? 
          WHERE mutation_id = ?
        ''', [jsonEncode(result.merged!), jsonEncode(remoteData), version, mutId]);
      }
    }
  }

  static Future<void> upsertRow(
    SqliteWriteContext tx,
    String entity,
    String id,
    Map<String, dynamic> data,
    int version,
    int now, [
    dynamic expiresAtOrSnapshot,
  ]) async {
    final dataMap = Map<String, dynamic>.from(data);
    dataMap['id'] = id;
    dataMap['version'] = version;
    dataMap['updated_at'] = now;
    final expiresAt = expiresAtOrSnapshot is int
        ? expiresAtOrSnapshot
        : (data['expires_at'] as int?);
    if (expiresAt != null) {
      dataMap['expires_at'] = expiresAt;
    }
    final dataJson = jsonEncode(dataMap);

    await tx.execute('''
      INSERT INTO "$entity" ("id", "version", "updated_at", "expires_at", "data_json")
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        version = excluded.version,
        updated_at = excluded.updated_at,
        expires_at = excluded.expires_at,
        data_json = excluded.data_json;
    ''', [id, version, now, expiresAt, dataJson]);
  }
}
