/// Defines configuration presets for the offline-first synchronization engine.
enum SyncProfile {
  /// Basic: Minimal complexity.
  /// - Conflict Resolution: Last-Write-Wins (LWW).
  /// - Dead-Letter Queue: Disabled (simple failure status).
  /// - Queue Ordering: Simple FIFO (no DAG holding).
  basic,

  /// Standard (Default): Robust consumer-grade offline-first sync.
  /// - Conflict Resolution: 3-Way Column-Level Auto-Merge.
  /// - Dead-Letter Queue: Poison-pill quarantine enabled.
  /// - Queue Ordering: Simple FIFO.
  standard,

  /// Enterprise: Maximum distributed guarantees for mission-critical apps.
  /// - Conflict Resolution: 3-Way Column Auto-Merge with RFC 9457 Invariant Validation.
  /// - Dead-Letter Queue: Poison-pill quarantine enabled.
  /// - Queue Ordering: Parent-Child DAG selective holding (blocks only dependent children).
  enterprise,
}
