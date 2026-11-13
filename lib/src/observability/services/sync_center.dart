import 'dart:async';
import 'package:sqlite3/sqlite3.dart' show ResultSet;
import '../../storage/sync_storage.dart';
import '../../client/domain/policies/debounce_stream_transformer.dart';
import '../domain/models/sync_item_info.dart';
import '../domain/models/orbit_summary.dart';
import '../domain/models/value_listenable.dart';

/// Unified developer surface for sync observability, telemetry, and manual resolution controls.
abstract class OrbitSyncCenter {
  /// Real-time live stream of outbox items, throttled to 100ms and auto-paused when canceled.
  Stream<List<SyncItemInfo>> watchItems({SyncItemStatus? filterStatus});

  /// Real-time live summary for UI badges and indicator pills.
  ValueListenable<OrbitSummary> get summary;

  /// Triggers an immediate network sync drain.
  Future<void> syncNow();

  /// Retries a single rejected, failed, or quarantined mutation.
  Future<void> retryItem(String mutationId);

  /// Retries all recoverable mutations currently in failed, validation_error, or dlq status.
  Future<void> retryAllFailed();

  /// Releases resources and stops active timers.
  Future<void> dispose();
}

class OrbitSyncCenterImpl implements OrbitSyncCenter {
  final SyncStorage storage;
  final Future<void> Function() syncNowFn;
  final int Function()? nowMsProvider;

  late final OrbitValueNotifier<OrbitSummary> _summaryNotifier;
  StreamSubscription<ResultSet>? _summarySub;
  bool _isDisposed = false;

  OrbitSyncCenterImpl({
    required this.storage,
    required this.syncNowFn,
    this.nowMsProvider,
  }) {
    _summaryNotifier = OrbitValueNotifier<OrbitSummary>(
      const OrbitSummary(),
      onActive: _startSummaryWatching,
      onInactive: _stopSummaryWatching,
    );
    // Initial one-shot load for immediate value availability
    _refreshSummary();
  }

  Future<void> _refreshSummary() async {
    try {
      final rows = await storage.db.getAll(
        "SELECT status, COUNT(*) as cnt, MIN(created_at) as oldest FROM _sync_outbox GROUP BY status",
      );
      if (!_isDisposed) {
        _summaryNotifier.value = OrbitSummary.fromRows(rows);
      }
    } catch (_) {}
  }

  void _startSummaryWatching() {
    if (_isDisposed || _summarySub != null) return;
    _refreshSummary();
    _summarySub = storage
        .watch(
            "SELECT status, COUNT(*) as cnt, MIN(created_at) as oldest FROM _sync_outbox GROUP BY status")
        .leadingImmediateDebounce(const Duration(milliseconds: 100))
        .listen(
      (rs) {
        if (!_isDisposed) {
          _summaryNotifier.value = OrbitSummary.fromRows(rs);
        }
      },
      onError: (_) {},
    );
  }

  void _stopSummaryWatching() {
    _summarySub?.cancel();
    _summarySub = null;
  }

  @override
  ValueListenable<OrbitSummary> get summary => _summaryNotifier;

  @override
  Stream<List<SyncItemInfo>> watchItems({SyncItemStatus? filterStatus}) {
    return Stream<List<SyncItemInfo>>.multi((multiController) {
      String query;
      List<dynamic> params = const [];

      if (filterStatus != null) {
        query =
            'SELECT * FROM _sync_outbox WHERE status = ? ORDER BY created_at DESC';
        params = [_statusToDbString(filterStatus)];
      } else {
        query = 'SELECT * FROM _sync_outbox ORDER BY created_at DESC';
      }

      final sub = storage
          .watch(query, parameters: params)
          .leadingImmediateDebounce(const Duration(milliseconds: 100))
          .map((rs) => rs
              .map((r) => SyncItemInfo.fromRow(r, nowMs: nowMsProvider?.call()))
              .toList())
          .listen(
            multiController.addSync,
            onError: multiController.addErrorSync,
            onDone: multiController.closeSync,
          );

      multiController.onCancel = () => sub.cancel();
      multiController.onPause = sub.pause;
      multiController.onResume = sub.resume;
    });
  }

  @override
  Future<void> syncNow() async {
    await syncNowFn();
  }

  @override
  Future<void> retryItem(String mutationId) async {
    await storage.db.execute(
      "UPDATE _sync_outbox SET status = 'pending', retry_count = 0, next_retry_at = NULL WHERE mutation_id = ?",
      [mutationId],
    );
    await syncNow();
  }

  @override
  Future<void> retryAllFailed() async {
    await storage.db.execute(
      "UPDATE _sync_outbox SET status = 'pending', retry_count = 0, next_retry_at = NULL WHERE status IN ('failed', 'dlq', 'validation_error', 'conflict')",
    );
    await syncNow();
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    _stopSummaryWatching();
    _summaryNotifier.dispose();
  }

  static String _statusToDbString(SyncItemStatus status) {
    switch (status) {
      case SyncItemStatus.inFlight:
        return 'in_flight';
      case SyncItemStatus.synced:
        return 'synced';
      case SyncItemStatus.rejected:
        return 'validation_error';
      case SyncItemStatus.failed:
        return 'failed';
      case SyncItemStatus.held:
        return 'held';
      case SyncItemStatus.dlq:
        return 'dlq';
      case SyncItemStatus.pending:
        return 'pending';
    }
  }
}
