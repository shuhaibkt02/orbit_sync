import 'package:sqlite_async/sqlite_async.dart';
import 'sync_validator.dart';

/// Manages cache pruning, TTL expiration, WAL checkpoints, and chunked queries.
class CacheCleaner {
  /// Prunes completed synced outbox records older than [olderThan].
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

  /// Prunes expired local domain cache records where `expires_at < now`.
  /// Shielding: Protects dirty records that have active outbox mutations from being wiped.
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

  /// Triggers a WAL checkpoint. If [truncate] is true, shrinks WAL file to 0 bytes.
  static Future<void> checkpoint(
    SqliteDatabase db, {
    bool truncate = false,
  }) async {
    final mode = truncate ? 'TRUNCATE' : 'PASSIVE';
    await db.execute('PRAGMA wal_checkpoint($mode);');
  }

  /// Slices [items] into safe chunks below SQLite's variable limit (default 250)
  /// and runs [action] for each chunk, preventing SQLITE_MAX_VARIABLE_NUMBER crashes.
  static Future<void> batchChunked<T>(
    List<T> items, {
    int chunkSize = 250,
    required Future<void> Function(List<T> chunk) action,
  }) async {
    for (var i = 0; i < items.length; i += chunkSize) {
      final end = (i + chunkSize < items.length) ? i + chunkSize : items.length;
      await action(items.sublist(i, end));
    }
  }
}
