import 'package:sqlite_async/sqlite_async.dart';
import 'sync_validator.dart';

/// Repository for mapping local temporary IDs to canonical server-assigned IDs.
class IdMapRepository {
  final SqliteDatabase db;

  IdMapRepository(this.db);

  /// Records a local temporary ID to canonical server ID mapping.
  Future<void> registerServerId({
    required String entity,
    required String localTempId,
    required String canonicalServerId,
  }) async {
    SyncValidator.validateEntity(entity);
    SyncValidator.validateId(localTempId);
    SyncValidator.validateId(canonicalServerId);

    final now = DateTime.now().millisecondsSinceEpoch;
    await db.execute('''
      INSERT OR REPLACE INTO _sync_id_map (entity_name, local_temp_id, canonical_server_id, created_at)
      VALUES (?, ?, ?, ?)
    ''', [entity, localTempId, canonicalServerId, now]);
  }

  /// Resolves the canonical server ID for a local temporary ID.
  Future<String?> getCanonicalServerId({
    required String entity,
    required String localTempId,
  }) async {
    SyncValidator.validateEntity(entity);
    SyncValidator.validateId(localTempId);

    final rows = await db.getAll(
      'SELECT canonical_server_id FROM _sync_id_map WHERE entity_name = ? AND local_temp_id = ?',
      [entity, localTempId],
    );
    return rows.isNotEmpty ? rows.first['canonical_server_id'] as String? : null;
  }

  /// Resolves the local temporary ID for a canonical server ID.
  Future<String?> getLocalTempId({
    required String entity,
    required String canonicalServerId,
  }) async {
    SyncValidator.validateEntity(entity);
    SyncValidator.validateId(canonicalServerId);

    final rows = await db.getAll(
      'SELECT local_temp_id FROM _sync_id_map WHERE entity_name = ? AND canonical_server_id = ?',
      [entity, canonicalServerId],
    );
    return rows.isNotEmpty ? rows.first['local_temp_id'] as String? : null;
  }
}
