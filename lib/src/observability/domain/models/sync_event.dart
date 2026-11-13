/// Sealed base class for all typed observability events across the 5 trigger sources.
sealed class SyncEvent {
  final DateTime timestamp;
  const SyncEvent({required this.timestamp});
}

// 1. Connectivity Triggers
class OnlineEvent extends SyncEvent {
  final String? networkType;
  const OnlineEvent({required super.timestamp, this.networkType});
}

class OfflineEvent extends SyncEvent {
  final String? reason;
  const OfflineEvent({required super.timestamp, this.reason});
}

class ProbeTimeoutEvent extends SyncEvent {
  final String? targetUrl;
  final int latencyMs;
  final String? errorMessage;
  const ProbeTimeoutEvent(
      {required super.timestamp,
      this.targetUrl,
      this.latencyMs = 0,
      this.errorMessage});
}

// 2. Storage Triggers
class MutationQueuedEvent extends SyncEvent {
  final String mutationId;
  final String entity;
  final String entityId;
  const MutationQueuedEvent(
      {required super.timestamp,
      required this.mutationId,
      required this.entity,
      required this.entityId});
}

class MutationCoalescedEvent extends SyncEvent {
  final String mutationId;
  final String entity;
  final String entityId;
  const MutationCoalescedEvent(
      {required super.timestamp,
      required this.mutationId,
      required this.entity,
      required this.entityId});
}

class DatabasePrunedEvent extends SyncEvent {
  final int prunedCount;
  final String pruneType;
  const DatabasePrunedEvent(
      {required super.timestamp,
      required this.prunedCount,
      this.pruneType = 'expired'});
}

class StorageWarningEvent extends SyncEvent {
  final String message;
  final int? currentBytes;
  const StorageWarningEvent(
      {required super.timestamp, required this.message, this.currentBytes});
}

// 3. SLA Monitor Triggers
class SlaWarningEvent extends SyncEvent {
  final String mutationId;
  final String entity;
  final String entityId;
  final Duration age;
  final Duration sla;
  const SlaWarningEvent(
      {required super.timestamp,
      required this.mutationId,
      required this.entity,
      required this.entityId,
      required this.age,
      required this.sla});
}

class SlaBreachedEvent extends SyncEvent {
  final String mutationId;
  final String entity;
  final String entityId;
  final Duration age;
  final Duration sla;
  const SlaBreachedEvent(
      {required super.timestamp,
      required this.mutationId,
      required this.entity,
      required this.entityId,
      required this.age,
      required this.sla});
}

// 4. Consensus & Engine Triggers
class ConflictDetectedEvent extends SyncEvent {
  final String entity;
  final String entityId;
  final Map<String, dynamic> localRecord;
  final Map<String, dynamic> remoteRecord;
  final Map<String, dynamic>? mergedRecord;
  const ConflictDetectedEvent(
      {required super.timestamp,
      required this.entity,
      required this.entityId,
      this.localRecord = const {},
      this.remoteRecord = const {},
      this.mergedRecord});
}

class PoisonPillQuarantinedEvent extends SyncEvent {
  final String mutationId;
  final String entity;
  final String entityId;
  final String reason;
  const PoisonPillQuarantinedEvent(
      {required super.timestamp,
      required this.mutationId,
      required this.entity,
      required this.entityId,
      required this.reason});
}

class CascadeFailureEvent extends SyncEvent {
  final String parentMutationId;
  final String childMutationId;
  const CascadeFailureEvent(
      {required super.timestamp,
      required this.parentMutationId,
      required this.childMutationId});
}

class SyncRejectedEvent extends SyncEvent {
  final String entity;
  final String entityId;
  final String errorMessage;
  final int? statusCode;
  const SyncRejectedEvent(
      {required super.timestamp,
      required this.entity,
      required this.entityId,
      required this.errorMessage,
      this.statusCode});
}

// 5. Transport Triggers
class RateLimitedEvent extends SyncEvent {
  final int retryAfterSeconds;
  final String? endpoint;
  const RateLimitedEvent(
      {required super.timestamp, this.retryAfterSeconds = 1, this.endpoint});
}

class AuthExpiredEvent extends SyncEvent {
  const AuthExpiredEvent({required super.timestamp});
}
