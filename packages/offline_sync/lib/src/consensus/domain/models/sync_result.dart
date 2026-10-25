/// Push status outcomes for Layer 2 consensus engine.
enum SyncPushStatus {
  success,
  networkError,
  conflict,
  validationError,
  poisonPill,
  unauthorized,
  needsUpgrade,
}

/// Pull status outcomes for Layer 2 consensus engine.
enum SyncPullStatus {
  success,
  networkError,
  expiredCursor,
  unauthorized,
}

/// Dynamic schema upcast migrator callback.
typedef MutationMigrator = Map<String, dynamic> Function(
  int fromVersion,
  int toVersion,
  String entity,
  Map<String, dynamic> payload,
);

/// Structured outcome of an outbox push dispatch.
class SyncPushResult {
  final SyncPushStatus status;
  final int applied;
  final String? errorMessage;
  final Map<String, dynamic>? details;

  const SyncPushResult({
    required this.status,
    this.applied = 0,
    this.errorMessage,
    this.details,
  });
}

/// Structured outcome of a remote pull pagination cycle.
class SyncPullResult {
  final SyncPullStatus status;
  final int changeCount;
  final int nextCursor;
  final bool hasMore;
  final String? errorMessage;

  const SyncPullResult({
    required this.status,
    this.changeCount = 0,
    this.nextCursor = 0,
    this.hasMore = false,
    this.errorMessage,
  });
}
