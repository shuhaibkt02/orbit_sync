import 'dart:async';
import '../../storage/sync_storage.dart';
import '../domain/models/sync_event.dart';

/// Background evaluator for business SLA deadlines and early-warning alerts.
///
/// Emits [SlaWarningEvent] when 80% of allowed sync duration has elapsed,
/// and [SlaBreachedEvent] when the full deadline has expired without syncing.
class SlaMonitor {
  final SyncStorage storage;
  final Duration checkInterval;
  final int Function()? nowMsProvider;

  final Set<String> _warned = {};
  final Set<String> _breached = {};
  final StreamController<SyncEvent> _controller = StreamController<SyncEvent>.broadcast();
  Timer? _timer;
  bool _isEvaluating = false;

  SlaMonitor({
    required this.storage,
    this.checkInterval = const Duration(seconds: 30),
    this.nowMsProvider,
  });

  Stream<SyncEvent> get events => _controller.stream;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(checkInterval, (_) => evaluate());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Evaluates active outbox records against their SLA deadlines.
  Future<List<SyncEvent>> evaluate({int? nowMs}) async {
    if (_isEvaluating) return const [];
    _isEvaluating = true;
    try {
      final now = nowMs ?? nowMsProvider?.call() ?? DateTime.now().toUtc().millisecondsSinceEpoch;
      final rows = await storage.db.getAll('''
        SELECT mutation_id, entity_name, entity_id, created_at, sla_seconds
        FROM _sync_outbox
        WHERE status IN ('pending', 'in_flight', 'failed', 'held')
          AND sla_seconds IS NOT NULL
          AND sla_seconds > 0
      ''');

      final activeIds = <String>{};
      final emitted = <SyncEvent>[];

      for (final r in rows) {
        final id = r['mutation_id'] as String;
        activeIds.add(id);

        final createdAt = r['created_at'] as int;
        final slaSeconds = r['sla_seconds'] as int;
        final slaMs = slaSeconds * 1000;
        final elapsedMs = now - createdAt;
        if (elapsedMs < 0 || slaMs <= 0) continue;

        final elapsed = Duration(milliseconds: elapsedMs);
        final sla = Duration(seconds: slaSeconds);
        final entity = r['entity_name'] as String;
        final entityId = r['entity_id'] as String;

        if (elapsedMs >= slaMs) {
          if (!_breached.contains(id)) {
            _breached.add(id);
            final event = SlaBreachedEvent(
              timestamp: DateTime.fromMillisecondsSinceEpoch(now, isUtc: true),
              mutationId: id,
              entity: entity,
              entityId: entityId,
              age: elapsed,
              sla: sla,
            );
            emitted.add(event);
            if (!_controller.isClosed) _controller.add(event);
          }
        } else if (elapsedMs >= (slaMs * 0.8).round()) {
          if (!_warned.contains(id) && !_breached.contains(id)) {
            _warned.add(id);
            final event = SlaWarningEvent(
              timestamp: DateTime.fromMillisecondsSinceEpoch(now, isUtc: true),
              mutationId: id,
              entity: entity,
              entityId: entityId,
              age: elapsed,
              sla: sla,
            );
            emitted.add(event);
            if (!_controller.isClosed) _controller.add(event);
          }
        }
      }

      // Evict items that are no longer pending/active to prevent set bloat
      _warned.removeWhere((id) => !activeIds.contains(id));
      _breached.removeWhere((id) => !activeIds.contains(id));

      return emitted;
    } finally {
      _isEvaluating = false;
    }
  }

  Future<void> dispose() async {
    stop();
    _warned.clear();
    _breached.clear();
    if (!_controller.isClosed) await _controller.close();
  }
}
