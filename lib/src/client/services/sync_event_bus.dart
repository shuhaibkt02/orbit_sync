import 'dart:async';
import '../domain/models/orbit_sync_event.dart';
import '../domain/models/sync_summary.dart';

/// Throttled event bus for publishing and observing synchronization telemetry.
///
/// Throttles [SyncProgress] events to a maximum frequency of 100ms per [syncId]
/// to prevent Dart event loop microtask flooding and UI frame drops (Challenge 2).
class SyncEventBus {
  final StreamController<OrbitSyncEvent> _controller =
      StreamController<OrbitSyncEvent>.broadcast();

  final Map<String, int> _lastProgressEmissionMs = {};
  static const int minProgressIntervalMs = 100;

  Stream<OrbitSyncEvent> get stream => _controller.stream;

  void emitStarted({required String syncId, String trigger = 'manual'}) {
    if (_controller.isClosed) return;
    _controller.add(SyncStarted(
      syncId: syncId,
      timestamp: DateTime.now().toUtc(),
      trigger: trigger,
    ));
  }

  void emitProgress({
    required String syncId,
    required double percentage,
    required int applied,
    required int total,
  }) {
    if (_controller.isClosed) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastProgressEmissionMs[syncId] ?? 0;
    if (now - last < minProgressIntervalMs && percentage < 1.0) {
      return; // Throttled to protect UI 60/120 FPS rendering
    }
    _lastProgressEmissionMs[syncId] = now;
    _controller.add(SyncProgress(
      syncId: syncId,
      timestamp: DateTime.now().toUtc(),
      progressPercentage: percentage,
      appliedCount: applied,
      totalCount: total,
    ));
  }

  void emitFinished({required String syncId, required SyncSummary summary}) {
    if (_controller.isClosed) return;
    _lastProgressEmissionMs.remove(syncId);
    _controller.add(SyncFinished(
      syncId: syncId,
      timestamp: DateTime.now().toUtc(),
      summary: summary,
    ));
  }

  void emitFailed({
    required String syncId,
    required String errorMessage,
    int? statusCode,
  }) {
    if (_controller.isClosed) return;
    _lastProgressEmissionMs.remove(syncId);
    _controller.add(SyncFailed(
      syncId: syncId,
      timestamp: DateTime.now().toUtc(),
      errorMessage: errorMessage,
      statusCode: statusCode,
    ));
  }

  Future<void> dispose() async {
    _lastProgressEmissionMs.clear();
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }
}
