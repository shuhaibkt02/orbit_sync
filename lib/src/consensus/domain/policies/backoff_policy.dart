import 'dart:math';

/// Deterministic, jittered exponential backoff policy for transient sync failures.
class BackoffPolicy {
  final Duration base;
  final Duration max;
  final double jitterFraction;
  final int maxRetries;
  final Random _rng;

  BackoffPolicy({
    this.base = const Duration(seconds: 1),
    this.max = const Duration(minutes: 15),
    this.jitterFraction = 0.25,
    this.maxRetries = 5,
    Random? rng,
  }) : _rng = rng ?? Random();

  /// Calculates delay duration for [retryCount].
  Duration delayFor(int retryCount) {
    if (retryCount <= 0) return Duration.zero;
    final expShift = (retryCount - 1).clamp(0, 20);
    final expMs = base.inMilliseconds * (1 << expShift);
    final capped = expMs.clamp(0, max.inMilliseconds);
    if (jitterFraction <= 0) return Duration(milliseconds: capped);
    final jitter = (capped * jitterFraction).round();
    final offset = jitter > 0 ? _rng.nextInt(jitter * 2 + 1) - jitter : 0;
    return Duration(
        milliseconds: (capped + offset).clamp(0, max.inMilliseconds));
  }

  /// Calculates next retry timestamp in epoch milliseconds.
  int nextRetryAt(int retryCount, int nowMs) =>
      nowMs + delayFor(retryCount).inMilliseconds;
}
