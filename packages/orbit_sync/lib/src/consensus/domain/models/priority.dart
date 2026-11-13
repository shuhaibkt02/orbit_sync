/// Priority tiers for offline mutations (Blueprint Layer 1 & 5).
enum Priority {
  /// Low-priority background sync, telemetry, analytics.
  background(0),

  /// Standard business actions.
  normal(1),

  /// Expedited queue item.
  high(2),

  /// Critical action (e.g. Payments, Incident Reports) that dispatches first.
  critical(3);

  final int value;
  const Priority(this.value);

  /// Converts an integer (0..3) into a [Priority].
  static Priority fromInt(int val) {
    return switch (val) {
      >= 3 => Priority.critical,
      2 => Priority.high,
      1 => Priority.normal,
      _ => Priority.background,
    };
  }

  bool operator >(Priority other) => value > other.value;
  bool operator >=(Priority other) => value >= other.value;
  bool operator <(Priority other) => value < other.value;
  bool operator <=(Priority other) => value <= other.value;
}
