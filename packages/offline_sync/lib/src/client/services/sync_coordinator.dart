import 'dart:async';
import '../../storage/sync_storage.dart';
import '../../consensus/sync_worker.dart';
import '../../transport/infrastructure/http_sync_transport.dart';
import '../domain/models/sync_job.dart';
import '../domain/models/sync_summary.dart';
import 'sync_event_bus.dart';

/// Coordinates execution of bidirectional sync cycles, event emission,
/// and returns operation-scoped [SyncJob] handles (Challenge 2).
class SyncCoordinator {
  final SyncWorker worker;
  final SyncEventBus eventBus;

  bool _isSyncing = false;
  Completer<void>? _syncCompleter;

  SyncCoordinator({
    required this.worker,
    required this.eventBus,
  });

  bool get isSyncing => _isSyncing;
  Future<void>? get currentInFlightSync => _syncCompleter?.future;

  SyncJob triggerSync({
    bool force = false,
    bool isPaused = false,
    bool isClosed = false,
  }) {
    final syncId = UuidV7.generate();
    final job = SyncJob(syncId: syncId);

    if (_isSyncing || isPaused || isClosed) {
      job.complete(SyncSummary.empty);
      return job;
    }

    _isSyncing = true;
    _syncCompleter = Completer<void>();
    eventBus.emitStarted(syncId: syncId);

    () async {
      int totalApplied = 0;
      int totalFailed = 0;
      final sw = Stopwatch()..start();

      try {
        if (worker.serverUrl.isNotEmpty || worker.transport is! HttpSyncTransport) {
          await worker.pullAll();
        }

        while (true) {
          final res = await worker.pushBatch(batchSize: 20, force: force);
          totalApplied += res.applied;
          if (res.status != SyncPushStatus.success || res.applied == 0) {
            if (res.status != SyncPushStatus.success) totalFailed++;
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
        _syncCompleter?.complete();
        _syncCompleter = null;
      }
    }();

    return job;
  }
}
