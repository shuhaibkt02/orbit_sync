import 'dart:io';
import 'dart:math';

/// Parses standard HTTP 429 `Retry-After` headers (seconds or HTTP-date)
/// and injects ±20% randomized jitter to protect servers from thundering herds.
class RetryAfterParser {
  final Random _random;

  RetryAfterParser({Random? random}) : _random = random ?? Random();

  /// Calculates the next retry timestamp (epoch ms) with optional jitter.
  int parseNextRetryAt(
    String? header,
    int nowMs, {
    required Duration fallbackDelay,
    bool withJitter = true,
  }) {
    final baseDelayMs =
        _extractBaseDelayMs(header, nowMs, fallbackDelay.inMilliseconds);
    final delay = withJitter ? applyJitter(baseDelayMs) : baseDelayMs;
    return nowMs + delay;
  }

  int _extractBaseDelayMs(String? header, int nowMs, int fallbackMs) {
    if (header == null || header.trim().isEmpty) return fallbackMs;
    final clean = header.trim();
    final seconds = int.tryParse(clean);
    if (seconds != null) return max(0, seconds * 1000);
    try {
      final date = HttpDate.parse(clean);
      final delay = date.millisecondsSinceEpoch - nowMs;
      return delay > 0 ? delay : fallbackMs;
    } catch (_) {
      return fallbackMs;
    }
  }

  /// Injects ±20% randomized full jitter into [baseDelayMs].
  int applyJitter(int baseDelayMs) {
    if (baseDelayMs <= 0) return 0;
    // Jitter range: ±20% -> factor [0.80, 1.20]
    final jitterFactor = 0.8 + (_random.nextDouble() * 0.4);
    return (baseDelayMs * jitterFactor).round();
  }
}
