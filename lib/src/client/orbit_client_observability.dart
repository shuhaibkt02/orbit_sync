import '../observability/domain/models/sync_event.dart';
import '../observability/services/sync_logger.dart';
import 'orbit_client.dart';

/// Observability and telemetry forwarders on [OrbitClient].
extension OrbitClientObservability on OrbitClient {
  Stream<OnlineEvent> get onOnline => observer.onOnline;
  Stream<OfflineEvent> get onOffline => observer.onOffline;
  Stream<ProbeTimeoutEvent> get onProbeTimeout => observer.onProbeTimeout;
  Stream<MutationQueuedEvent> get onMutationQueued => observer.onMutationQueued;
  Stream<MutationCoalescedEvent> get onMutationCoalesced => observer.onMutationCoalesced;
  Stream<DatabasePrunedEvent> get onDatabasePruned => observer.onDatabasePruned;
  Stream<StorageWarningEvent> get onStorageWarning => observer.onStorageWarning;
  Stream<SlaWarningEvent> get onSlaWarning => observer.onSlaWarning;
  Stream<SlaBreachedEvent> get onSlaBreached => observer.onSlaBreached;
  Stream<ConflictDetectedEvent> get onConflictDetected => observer.onConflictDetected;
  Stream<PoisonPillQuarantinedEvent> get onPoisonPillQuarantined => observer.onPoisonPillQuarantined;
  Stream<CascadeFailureEvent> get onCascadeFailure => observer.onCascadeFailure;
  Stream<SyncRejectedEvent> get onSyncRejected => observer.onSyncRejected;
  Stream<RateLimitedEvent> get onRateLimited => observer.onRateLimited;
  Stream<AuthExpiredEvent> get onAuthExpired => observer.onAuthExpired;
  SyncLogger get logger => observer.logger;
}
