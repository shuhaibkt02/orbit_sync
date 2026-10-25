import 'dart:async';
import '../../storage/sync_storage.dart';
import '../../consensus/sync_worker.dart';
import '../../connectivity/connectivity_monitor.dart';

/// Orchestrates atomic 4-step graceful shutdown with a strict hardware timeout budget (Challenge 8).
class DrainOrchestrator {
  final SyncStorage storage;
  final SyncWorker worker;
  final ConnectivityMonitor connectivity;
  final List<StreamController<dynamic>> activeWatchControllers;
  final Future<void> Function()? awaitInFlightSync;

  bool _isClosing = false;
  bool _isClosed = false;
  Completer<void>? _closeCompleter;

  DrainOrchestrator({
    required this.storage,
    required this.worker,
    required this.connectivity,
    this.activeWatchControllers = const [],
    this.awaitInFlightSync,
  });

  bool get isClosing => _isClosing;
  bool get isClosed => _isClosed;

  Future<void> executeClose({
    Duration drainTimeout = const Duration(seconds: 3),
    Timer? periodicTimer,
  }) async {
    if (_isClosed) return;
    if (_isClosing) return _closeCompleter!.future;

    _isClosing = true;
    _closeCompleter = Completer<void>();

    try {
      // Step 1: Shut inbound gate (cancel timers, dispose connectivity)
      periodicTimer?.cancel();
      connectivity.dispose();

      // Step 2 & 3: Drain active in-flight sync with hard timeout budget
      if (awaitInFlightSync != null) {
        try {
          await awaitInFlightSync!().timeout(drainTimeout);
        } on TimeoutException {
          // Hard budget expired: sever hanging transport connections immediately
          worker.transport.dispose();

          // Atomically revert in-flight mutations to 'pending' to prevent zombie states
          await storage.db.execute(
            "UPDATE _sync_outbox SET status = 'pending' WHERE status = 'in_flight'",
          );
        } catch (_) {
          try {
            await storage.db.execute(
              "UPDATE _sync_outbox SET status = 'pending' WHERE status = 'in_flight'",
            );
          } catch (_) {}
        }
      }

      // Step 4: Close active reactive streams and sever SQLite reader/writer pool
      for (final controller in List<StreamController<dynamic>>.from(activeWatchControllers)) {
        if (!controller.isClosed) {
          await controller.close();
        }
      }
      activeWatchControllers.clear();

      worker.dispose();
      await storage.close();
    } finally {
      _isClosed = true;
      _closeCompleter?.complete();
    }
  }
}
