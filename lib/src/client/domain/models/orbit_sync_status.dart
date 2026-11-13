/// Lifecycle synchronization status of an entity record.
enum OrbitSyncStatus {
  /// Record created/updated locally and queued in the outbox.
  pending,

  /// Mutation is currently crossing the network.
  inFlight,

  /// Record is confirmed committed on the remote backend.
  synced,

  /// Mutation was permanently rejected by the server (e.g. HTTP 422)
  /// but preserved locally in editable draft state.
  rejected,

  /// Record is soft-deleted locally within its undo grace window.
  pendingDelete,

  /// Terminal failure or moved to Dead Letter Queue (DLQ).
  failed;

  /// Returns true if this status represents an uncommitted local modification.
  bool get isDirty =>
      this == pending ||
      this == inFlight ||
      this == rejected ||
      this == pendingDelete;
}
