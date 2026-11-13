import 'dart:async';
import '../../storage/sync_storage.dart';
import '../../consensus/sync_worker.dart';
import '../../observability/domain/models/sync_event.dart';
import '../domain/models/sync_job.dart';
import '../domain/models/sync_summary.dart';
import 'sync_event_bus.dart';

/// Coordinates execution of bidirectional sync cycles, event emission,
/// and returns operation-scoped [SyncJob] handles (Challenge 2).
class SyncCoordinator {
  final SyncWorker worker;
  final SyncEventBus eventBus;
  final void Function(SyncEvent event)? onEvent;

  bool _isSyncing = false;
  Completer<void>? _syncCompleter;
  SyncJob? _currentSyncJob;

  SyncCoordinator({
    required this.worker,
    required this.eventBus,
    this.onEvent,
  });

  bool get isSyncing => _isSyncing;
  Future<void>? get currentInFlightSync => _syncCompleter?.future;

  SyncJob triggerSync({
    bool force = false,
    bool isPaused = false,
    bool isClosed = false,
    bool pull = false,
  }) {
    final syncId = UuidV7.generate();
    final job = SyncJob(syncId: syncId);

    if (isClosed || isPaused) {
      job.complete(SyncSummary.empty);
      return job;
    }

    if (_isSyncing) {
      if (_currentSyncJob != null) {
        _currentSyncJob!.then(
          (summary) => job.complete(summary),
          onError: (e, st) => job.completeError(e, st),
        );
        return job;
      }
      job.complete(SyncSummary.empty);
      return job;
    }

    _isSyncing = true;
    _currentSyncJob = job;
    _syncCompleter = Completer<void>();
    eventBus.emitStarted(syncId: syncId);

    () async {
      int totalApplied = 0;
      int totalFailed = 0;
      final sw = Stopwatch()..start();

      try {
        if (pull) {
          await worker.pullAll();
        }

        while (true) {
          final res = await worker.pushBatch(batchSize: 20, force: force);
          totalApplied += res.applied;
          if (res.status != SyncPushStatus.success || res.applied == 0) {
            if (res.status != SyncPushStatus.success) {
              totalFailed++;
              if (res.status == SyncPushStatus.conflict) {
                onEvent?.call(ConflictDetectedEvent(timestamp: DateTime.now().toUtc(), entity: '', entityId: ''));
              } else if (res.status == SyncPushStatus.poisonPill) {
                onEvent?.call(PoisonPillQuarantinedEvent(
                  timestamp: DateTime.now().toUtc(),
                  mutationId: '',
                  entity: '',
                  entityId: '',
                  reason: res.errorMessage ?? 'Poison pill quarantined',
                ));
              } else if (res.errorMessage?.contains('Rate limited') == true) {
                onEvent?.call(RateLimitedEvent(timestamp: DateTime.now().toUtc()));
              } else if (res.status == SyncPushStatus.unauthorized) {
                onEvent?.call(AuthExpiredEvent(timestamp: DateTime.now().toUtc()));
              }
            }
            break;
          }
          eventBus.emitProgress(syncId: syncId, percentage: 0.5, applied: totalApplied, total: totalApplied);
        }

        final summary = SyncSummary(applied: totalApplied, failed: totalFailed, durationMs: sw.elapsedMilliseconds);
        eventBus.emitFinished(syncId: syncId, summary: summary);
        job.complete(summary);
      } catch (e) {
        eventBus.emitFailed(syncId: syncId, errorMessage: e.toString());
        job.complete(SyncSummary(applied: totalApplied, failed: totalFailed + 1, errorMessage: e.toString(), durationMs: sw.elapsedMilliseconds));
      } finally {
        _isSyncing = false;
        _currentSyncJob = null;
        _syncCompleter?.complete();
        _syncCompleter = null;
      }
    }();

    return job;
  }
}
