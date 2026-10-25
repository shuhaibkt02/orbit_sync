import 'package:sqlite_async/sqlite_async.dart';
import '../../domain/validation/sync_validator.dart';

/// SQLite helper for cache pruning, TTL cleanup, and checkpoints.
class SqliteCacheCleaner {
  static Future<int> pruneSynced(
    SqliteDatabase db, {
    Duration olderThan = const Duration(days: 7),
  }) async {
    final cutoff = DateTime.now().subtract(olderThan).millisecondsSinceEpoch;
    return await db.writeTransaction<int>((tx) async {
      await tx.execute(
        "DELETE FROM _sync_outbox WHERE status = 'synced' AND updated_at < ?",
        [cutoff],
      );
      final countRow = await tx.get('SELECT changes() as count;');
      return (countRow['count'] as int?) ?? 0;
    });
  }

  static Future<int> pruneExpiredCache(
    SqliteDatabase db,
    Set<String> knownColumns,
    String entity,
  ) async {
    SyncValidator.validateEntity(entity);

    final now = DateTime.now().millisecondsSinceEpoch;
    return await db.writeTransaction<int>((tx) async {
      final tableExists = knownColumns.contains('$entity:id') || (await tx.getAll(
        'SELECT 1 FROM sqlite_master WHERE type="table" AND name = ?',
        [entity],
      )).isNotEmpty;
      if (!tableExists) return 0;
      knownColumns.add('$entity:id');

      await tx.execute('''
        DELETE FROM "$entity" 
        WHERE expires_at IS NOT NULL 
          AND expires_at < ?
          AND id NOT IN (
            SELECT entity_id FROM _sync_outbox 
            WHERE entity_name = ? AND status IN ('pending', 'in_flight', 'held')
          );
      ''', [now, entity]);

      final countRow = await tx.get('SELECT changes() as count;');
      return (countRow['count'] as int?) ?? 0;
    });
  }

  static Future<void> checkpoint(
    SqliteDatabase db, {
    bool truncate = false,
  }) async {
    final mode = truncate ? 'TRUNCATE' : 'PASSIVE';
    await db.execute('PRAGMA wal_checkpoint($mode);');
  }
}
