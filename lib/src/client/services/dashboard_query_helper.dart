import 'dart:async';
import 'package:sqlite3/sqlite3.dart' show Row, ResultSet;
import '../../storage/sync_storage.dart';
import '../../consensus/domain/models/sync_status_summary.dart';
import '../../consensus/domain/models/sync_failure.dart';

/// Helper handling zero-SQL outbox queries, summaries, failures, and manual retries.
class DashboardQueryHelper {
  final SyncStorage storage;
  final Stream<ResultSet> Function(String query, {List<dynamic> parameters})
      watchFn;

  const DashboardQueryHelper({
    required this.storage,
    required this.watchFn,
  });

  Future<SyncStatusSummary> getSummary() async {
    final rows = await storage.db.getAll(
      "SELECT status, COUNT(*) as cnt, MIN(created_at) as oldest FROM _sync_outbox GROUP BY status",
    );
    return buildSummaryFromRows(rows);
  }

  Stream<SyncStatusSummary> watchSummary() {
    return watchFn(
      "SELECT status, COUNT(*) as cnt, MIN(created_at) as oldest FROM _sync_outbox GROUP BY status",
    ).map(buildSummaryFromRows);
  }

  Future<List<SyncFailure>> getFailures() async {
    final rows = await storage.db.getAll(
      "SELECT * FROM _sync_outbox WHERE status IN ('failed', 'dlq', 'validation_error') ORDER BY created_at DESC",
    );
    return rows.map(SyncFailure.fromRow).toList();
  }

  Stream<List<SyncFailure>> watchFailures() {
    return watchFn(
      "SELECT * FROM _sync_outbox WHERE status IN ('failed', 'dlq', 'validation_error') ORDER BY created_at DESC",
    ).map((rs) => rs.map(SyncFailure.fromRow).toList());
  }

  Future<List<OutboxRecord>> getRecords(
      {String? status, int limit = 100}) async {
    var sql = 'SELECT * FROM _sync_outbox';
    final params = <dynamic>[];
    if (status != null) {
      sql += ' WHERE status = ?';
      params.add(status);
    }
    sql += ' ORDER BY created_at DESC LIMIT ?';
    params.add(limit);
    final rows = await storage.db.getAll(sql, params);
    return rows.map(OutboxRecord.fromRow).toList();
  }

  Stream<List<OutboxRecord>> watchRecords({String? status, int limit = 100}) {
    var sql = 'SELECT * FROM _sync_outbox';
    final params = <dynamic>[];
    if (status != null) {
      sql += ' WHERE status = ?';
      params.add(status);
    }
    sql += ' ORDER BY created_at DESC LIMIT ?';
    params.add(limit);
    return watchFn(sql, parameters: params)
        .map((rs) => rs.map(OutboxRecord.fromRow).toList());
  }

  Future<List<OutboxRecord>> getStaleRecords({required Duration maxAge}) async {
    final cutoff =
        DateTime.now().millisecondsSinceEpoch - maxAge.inMilliseconds;
    final rows = await storage.db.getAll(
      "SELECT * FROM _sync_outbox WHERE status NOT IN ('synced') AND created_at <= ? ORDER BY created_at ASC",
      [cutoff],
    );
    return rows.map(OutboxRecord.fromRow).toList();
  }

  Stream<List<OutboxRecord>> watchStaleRecords({required Duration maxAge}) {
    return watchFn(
      "SELECT * FROM _sync_outbox WHERE status NOT IN ('synced') ORDER BY created_at ASC",
    ).map((rs) =>
        rs.map(OutboxRecord.fromRow).where((r) => r.isStale(maxAge)).toList());
  }

  Future<void> retryMutation(String mutationId) async {
    await storage.db.execute(
      "UPDATE _sync_outbox SET status = 'pending', retry_count = 0, next_retry_at = NULL WHERE mutation_id = ?",
      [mutationId],
    );
  }

  Future<void> retryAllFailed() async {
    await storage.db.execute(
      "UPDATE _sync_outbox SET status = 'pending', retry_count = 0, next_retry_at = NULL WHERE status IN ('failed', 'dlq', 'validation_error', 'conflict')",
    );
  }

  Future<void> cancelMutation(String mutationId) async {
    await storage.db.execute(
        "DELETE FROM _sync_outbox WHERE mutation_id = ?", [mutationId]);
  }

  Future<void> markSynced(String mutationId) async {
    await storage.db.execute(
      "UPDATE _sync_outbox SET status = 'synced', next_retry_at = NULL WHERE mutation_id = ?",
      [mutationId],
    );
  }

  static SyncStatusSummary buildSummaryFromRows(Iterable<Row> rows) {
    int pending = 0, inFlight = 0, synced = 0, failed = 0, total = 0;
    int? oldestPendingEpoch;

    for (final r in rows) {
      final status = r['status'] as String?;
      final count = (r['cnt'] as int?) ?? 0;
      final oldest = r['oldest'] as int?;
      total += count;

      if (status == 'pending' || status == 'in_flight' || status == 'held') {
        if (status == 'pending' || status == 'held') pending += count;
        if (status == 'in_flight') inFlight += count;
        if (oldest != null &&
            (oldestPendingEpoch == null || oldest < oldestPendingEpoch)) {
          oldestPendingEpoch = oldest;
        }
      } else if (status == 'synced') {
        synced += count;
      } else if (status == 'failed' ||
          status == 'dlq' ||
          status == 'validation_error' ||
          status == 'conflict') {
        failed += count;
        if (oldest != null &&
            (oldestPendingEpoch == null || oldest < oldestPendingEpoch)) {
          oldestPendingEpoch = oldest;
        }
      }
    }

    return SyncStatusSummary(
      pending: pending,
      inFlight: inFlight,
      synced: synced,
      failed: failed,
      total: total,
      oldestPendingAt: oldestPendingEpoch != null
          ? DateTime.fromMillisecondsSinceEpoch(oldestPendingEpoch)
          : null,
    );
  }
}
