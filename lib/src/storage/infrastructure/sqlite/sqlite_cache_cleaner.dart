import 'package:sqlite_async/sqlite_async.dart';
import '../../domain/validation/sync_validator.dart';

/// SQLite helper for cache pruning, TTL cleanup, and checkpoints.
class SqliteCacheCleaner {
  static Future<int> pruneSyncedOutbox(
    SqliteDatabase db, {
    Duration retention = const Duration(days: 7),
  }) async {
    final cutoff = DateTime.now().subtract(retention).millisecondsSinceEpoch;
    return await db.writeTransaction<int>((tx) async {
      await tx.execute(
        "DELETE FROM _sync_outbox WHERE status = 'synced' AND updated_at < ?",
        [cutoff],
      );
      final countRow = await tx.get('SELECT changes() as count;');
      return (countRow['count'] as int?) ?? 0;
    });
  }

  static Future<int> pruneSynced(
    SqliteDatabase db, {
    Duration olderThan = const Duration(days: 7),
  }) =>
      pruneSyncedOutbox(db, retention: olderThan);

  static Future<int> pruneExpiredCache(
    SqliteDatabase db,
    Set<String> knownColumns,
    String entity,
  ) async {
    SyncValidator.validateEntity(entity);

    final now = DateTime.now().millisecondsSinceEpoch;
    return await db.writeTransaction<int>((tx) async {
      final tableExists = knownColumns.contains('$entity:id') ||
          (await tx.getAll(
            'SELECT 1 FROM sqlite_master WHERE type="table" AND name = ?',
            [entity],
          ))
              .isNotEmpty;
      if (!tableExists) return 0;
      knownColumns.add('$entity:id');

      await tx.execute('''
        DELETE FROM "$entity" 
        WHERE expires_at IS NOT NULL 
          AND expires_at <= ?
          AND id NOT IN (
            SELECT entity_id FROM _sync_outbox 
            WHERE entity_name = ? AND status != 'synced'
          );
      ''', [now, entity]);

      final countRow = await tx.get('SELECT changes() as count;');
      return (countRow['count'] as int?) ?? 0;
    });
  }

  /// Prunes oldest records by [updated_at] (LRU) when the entity cache exceeds [maxCacheRecords].
  ///
  /// INVARIANT: Never prunes pinned records (`expires_at IS NULL`) or records with
  /// active pending outbox mutations.
  static Future<int> pruneToQuota(
    SqliteDatabase db,
    String entity, {
    required int maxCacheRecords,
  }) async {
    if (maxCacheRecords <= 0) return 0;
    SyncValidator.validateEntity(entity);

    return await db.writeTransaction<int>((tx) async {
      return await pruneToQuotaTx(tx, entity, maxCacheRecords: maxCacheRecords);
    });
  }

  /// Prunes oldest records by [updated_at] within an existing transaction context.
  static Future<int> pruneToQuotaTx(
    SqliteWriteContext tx,
    String entity, {
    required int maxCacheRecords,
  }) async {
    if (maxCacheRecords <= 0) return 0;
    SyncValidator.validateEntity(entity);

    final tableCheck = await tx.getAll(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      [entity],
    );
    if (tableCheck.isEmpty) return 0;

    final countRow = await tx.get('SELECT COUNT(*) as cnt FROM "$entity"');
    final currentCount = (countRow['cnt'] as int?) ?? 0;
    if (currentCount <= maxCacheRecords) return 0;

    final excess = currentCount - maxCacheRecords;
    await tx.execute('''
      DELETE FROM "$entity"
      WHERE id IN (
        SELECT id FROM "$entity"
        WHERE expires_at IS NOT NULL
          AND id NOT IN (
            SELECT entity_id FROM _sync_outbox 
            WHERE entity_name = ? AND status != 'synced'
          )
        ORDER BY updated_at ASC
        LIMIT ?
      )
    ''', [entity, excess]);

    final count = await tx.get('SELECT changes() as cnt;');
    return (count['cnt'] as int?) ?? 0;
  }

  static Future<void> checkpoint(
    SqliteDatabase db, {
    bool truncate = false,
  }) async {
    final mode = truncate ? 'TRUNCATE' : 'PASSIVE';
    await db.execute('PRAGMA wal_checkpoint($mode);');
  }
}
