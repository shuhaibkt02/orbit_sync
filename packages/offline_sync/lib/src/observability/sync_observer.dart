import 'dart:async';
import '../client/orbit_client.dart';
import 'domain/models/sync_event.dart';
import 'services/sync_logger.dart';
import 'services/sla_monitor.dart';

/// Central observability hub emitting typed telemetry streams and managing in-memory logs.
class SyncObserver {
  final SyncLogger logger;
  final SlaMonitor? slaMonitor;
  final Future<void> Function(String mutationId, {bool syncNow})? onRetryMutation;
  final Future<void> Function({bool syncNow})? onRetryAllFailed;

  final StreamController<SyncEvent> _controller = StreamController<SyncEvent>.broadcast();
  StreamSubscription<SyncEvent>? _slaSub;
  bool _isClosed = false;

  SyncObserver({
    SyncLogger? logger,
    this.slaMonitor,
    this.onRetryMutation,
    this.onRetryAllFailed,
  }) : logger = logger ?? SyncLogger() {
    _slaSub = slaMonitor?.events.listen(publish);
  }

  Stream<SyncEvent> get events => _controller.stream;

  Stream<T> _filter<T extends SyncEvent>() => events.where((e) => e is T).cast<T>();

  // 1. Connectivity Triggers
  Stream<OnlineEvent> get onOnline => _filter<OnlineEvent>();
  Stream<OfflineEvent> get onOffline => _filter<OfflineEvent>();
  Stream<ProbeTimeoutEvent> get onProbeTimeout => _filter<ProbeTimeoutEvent>();

  // 2. Storage Triggers
  Stream<MutationQueuedEvent> get onMutationQueued => _filter<MutationQueuedEvent>();
  Stream<MutationCoalescedEvent> get onMutationCoalesced => _filter<MutationCoalescedEvent>();
  Stream<DatabasePrunedEvent> get onDatabasePruned => _filter<DatabasePrunedEvent>();
  Stream<StorageWarningEvent> get onStorageWarning => _filter<StorageWarningEvent>();

  // 3. SLA Monitor Triggers
  Stream<SlaWarningEvent> get onSlaWarning => _filter<SlaWarningEvent>();
  Stream<SlaBreachedEvent> get onSlaBreached => _filter<SlaBreachedEvent>();

  // 4. Consensus & Engine Triggers
  Stream<ConflictDetectedEvent> get onConflictDetected => _filter<ConflictDetectedEvent>();
  Stream<PoisonPillQuarantinedEvent> get onPoisonPillQuarantined => _filter<PoisonPillQuarantinedEvent>();
  Stream<CascadeFailureEvent> get onCascadeFailure => _filter<CascadeFailureEvent>();
  Stream<SyncRejectedEvent> get onSyncRejected => _filter<SyncRejectedEvent>();

  // 5. Transport Triggers
  Stream<RateLimitedEvent> get onRateLimited => _filter<RateLimitedEvent>();
  Stream<AuthExpiredEvent> get onAuthExpired => _filter<AuthExpiredEvent>();

  /// Dispatches a typed [SyncEvent] to all stream listeners and logs it.
  void publish(SyncEvent event) {
    if (_isClosed) return;
    _controller.add(event);
    logger.logEvent(event);
  }

  /// Retries a specific quarantined or failed mutation by ID.
  Future<void> retryMutation(String mutationId, {bool syncNow = false}) async {
    await onRetryMutation?.call(mutationId, syncNow: syncNow);
  }

  /// Flushes all recoverable failures back to pending state.
  Future<void> retryAllFailed({bool syncNow = false}) async {
    await onRetryAllFailed?.call(syncNow: syncNow);
  }

  Future<void> dispose() async {
    if (_isClosed) return;
    _isClosed = true;
    await _slaSub?.cancel();
    await slaMonitor?.dispose();
    await _controller.close();
  }
}

/// Convenience extension providing instant access to typed telemetry streams on any OrbitClient.
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
