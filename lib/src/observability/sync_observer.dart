import 'dart:async';
import 'domain/models/sync_event.dart';
import 'services/sync_logger.dart';
import 'services/sla_monitor.dart';

/// Central observability hub emitting typed telemetry streams and managing in-memory logs.
class SyncObserver {
  final SyncLogger logger;
  SlaMonitor? slaMonitor;
  final Future<void> Function(String mutationId, {bool syncNow})?
      onRetryMutation;
  final Future<void> Function({bool syncNow})? onRetryAllFailed;

  final StreamController<SyncEvent> _controller =
      StreamController<SyncEvent>.broadcast();
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

  /// Re-binds SLA monitor to a new database instance after switching sessions.
  void updateSlaMonitor(SlaMonitor newSlaMonitor) {
    _slaSub?.cancel();
    slaMonitor?.dispose();
    slaMonitor = newSlaMonitor;
    _slaSub = newSlaMonitor.events.listen(publish);
  }

  Stream<SyncEvent> get events => _controller.stream;

  Stream<T> _filter<T extends SyncEvent>() =>
      events.where((e) => e is T).cast<T>();

  // 1. Connectivity Triggers
  Stream<OnlineEvent> get onOnline => _filter<OnlineEvent>();
  Stream<OfflineEvent> get onOffline => _filter<OfflineEvent>();
  Stream<ProbeTimeoutEvent> get onProbeTimeout => _filter<ProbeTimeoutEvent>();

  // 2. Storage Triggers
  Stream<MutationQueuedEvent> get onMutationQueued =>
      _filter<MutationQueuedEvent>();
  Stream<MutationCoalescedEvent> get onMutationCoalesced =>
      _filter<MutationCoalescedEvent>();
  Stream<DatabasePrunedEvent> get onDatabasePruned =>
      _filter<DatabasePrunedEvent>();
  Stream<StorageWarningEvent> get onStorageWarning =>
      _filter<StorageWarningEvent>();

  // 3. SLA Monitor Triggers
  Stream<SlaWarningEvent> get onSlaWarning => _filter<SlaWarningEvent>();
  Stream<SlaBreachedEvent> get onSlaBreached => _filter<SlaBreachedEvent>();

  // 4. Consensus & Engine Triggers
  Stream<ConflictDetectedEvent> get onConflictDetected =>
      _filter<ConflictDetectedEvent>();
  Stream<PoisonPillQuarantinedEvent> get onPoisonPillQuarantined =>
      _filter<PoisonPillQuarantinedEvent>();
  Stream<CascadeFailureEvent> get onCascadeFailure =>
      _filter<CascadeFailureEvent>();
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
