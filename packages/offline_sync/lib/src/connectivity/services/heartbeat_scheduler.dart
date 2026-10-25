import 'dart:async';

/// Manages low-cost periodic heartbeat polling while in a dead zone.
class HeartbeatScheduler {
  final Duration interval;
  final Future<bool> Function() onCheck;

  Timer? _timer;
  bool _isChecking = false;

  HeartbeatScheduler({
    this.interval = const Duration(seconds: 30),
    required this.onCheck,
  });

  /// Starts heartbeat timer if not already running.
  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) async {
      if (_isChecking) return;
      _isChecking = true;
      try {
        final online = await onCheck();
        if (online) {
          stop();
        }
      } finally {
        _isChecking = false;
      }
    });
  }

  /// Cancels active heartbeat timer.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// True if heartbeat scheduler is actively ticking.
  bool get isActive => _timer != null;

  /// Releases resources.
  void dispose() {
    stop();
  }
}
