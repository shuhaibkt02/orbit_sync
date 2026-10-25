/// Timing policy for signal stabilization and radio flapping prevention.
class DebouncePolicy {
  /// Stabilization window required for reconnect transitions (default: 3s).
  final Duration stabilizationDuration;

  /// Disconnect transitions must be dispatched immediately (0ms).
  final Duration disconnectDuration;

  const DebouncePolicy({
    this.stabilizationDuration = const Duration(seconds: 3),
    this.disconnectDuration = Duration.zero,
  });

  /// Default production debounce policy.
  static const standard = DebouncePolicy();

  /// Zero-delay debounce policy for fast deterministic unit tests.
  static const immediate = DebouncePolicy(
    stabilizationDuration: Duration.zero,
    disconnectDuration: Duration.zero,
  );
}
