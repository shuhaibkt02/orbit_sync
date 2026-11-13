/// High-level summary outcome of an executed synchronization job.
class SyncSummary {
  final int applied;
  final int failed;
  final int total;
  final String? errorMessage;
  final int durationMs;

  const SyncSummary({
    this.applied = 0,
    this.failed = 0,
    this.total = 0,
    this.errorMessage,
    this.durationMs = 0,
  });

  bool get hasErrors =>
      failed > 0 || (errorMessage != null && errorMessage!.isNotEmpty);
  bool get isSuccess => !hasErrors;

  static const empty = SyncSummary();

  @override
  String toString() =>
      'SyncSummary(applied: $applied, failed: $failed, total: $total, hasErrors: $hasErrors)';
}
