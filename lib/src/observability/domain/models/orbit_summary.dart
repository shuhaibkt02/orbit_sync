import 'package:sqlite3/sqlite3.dart' show Row;

/// High-level real-time summary of the synchronization subsystem.
/// Used for App Bar badges, pills, and synchronization health screens.
class OrbitSummary {
  final int pending;
  final int inFlight;
  final int synced;
  final int rejected;
  final int failed;
  final int total;
  final DateTime? oldestPendingAt;

  const OrbitSummary({
    this.pending = 0,
    this.inFlight = 0,
    this.synced = 0,
    this.rejected = 0,
    this.failed = 0,
    this.total = 0,
    this.oldestPendingAt,
  });

  /// True when outbox mutations are actively in-flight over the wire.
  bool get isSyncing => inFlight > 0;

  /// True when the outbox is completely caught up with zero errors or unpushed work.
  bool get isClean =>
      pending == 0 && inFlight == 0 && failed == 0 && rejected == 0;

  /// True when any mutations have encountered 422 rejections, conflicts, or permanent failure.
  bool get hasErrors => failed > 0 || rejected > 0;

  /// Time elapsed since the oldest pending mutation was enqueued.
  Duration? get oldestPendingAge => oldestPendingAt != null
      ? DateTime.now().toUtc().difference(oldestPendingAt!)
      : null;

  factory OrbitSummary.fromRows(Iterable<Row> rows) {
    int pending = 0,
        inFlight = 0,
        synced = 0,
        rejected = 0,
        failed = 0,
        total = 0;
    int? oldestEpoch;

    for (final r in rows) {
      final status = (r['status'] as String?) ?? '';
      final count = (r['cnt'] as int?) ?? 0;
      final oldest = r['oldest'] as int?;
      total += count;

      switch (status) {
        case 'pending':
        case 'held':
          pending += count;
          if (oldest != null && (oldestEpoch == null || oldest < oldestEpoch)) {
            oldestEpoch = oldest;
          }
          break;
        case 'in_flight':
          inFlight += count;
          if (oldest != null && (oldestEpoch == null || oldest < oldestEpoch)) {
            oldestEpoch = oldest;
          }
          break;
        case 'synced':
          synced += count;
          break;
        case 'validation_error':
          rejected += count;
          break;
        case 'failed':
        case 'dlq':
        case 'conflict':
          failed += count;
          break;
        default:
          pending += count;
          break;
      }
    }

    return OrbitSummary(
      pending: pending,
      inFlight: inFlight,
      synced: synced,
      rejected: rejected,
      failed: failed,
      total: total,
      oldestPendingAt: oldestEpoch != null
          ? DateTime.fromMillisecondsSinceEpoch(oldestEpoch, isUtc: true)
          : null,
    );
  }

  @override
  String toString() =>
      'OrbitSummary(pending: $pending, inFlight: $inFlight, synced: $synced, rejected: $rejected, failed: $failed, total: $total)';
}
