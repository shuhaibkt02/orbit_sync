import 'dart:async';
import '../domain/policies/debounce_policy.dart';

/// State machine managing asymmetric debouncing (3s reconnect guard, 0ms disconnect)
/// and software-simulated offline overrides.
class DebouncedStateMachine {
  final DebouncePolicy policy;

  bool _rawPhysicalOnline = true;
  bool _lastEmittedOnline = true;
  bool _simulateOffline = false;
  Timer? _stabilizationTimer;

  DebouncedStateMachine({
    this.policy = DebouncePolicy.standard,
  });

  /// True if current calculated reachability state is online (factoring in simulation).
  bool get isOnline => !_simulateOffline && _lastEmittedOnline;

  /// True if simulated offline mode is active.
  bool get simulateOffline => _simulateOffline;

  set simulateOffline(bool value) {
    if (_simulateOffline == value) return;
    _simulateOffline = value;
  }

  /// Processes physical reachability update with asymmetric debouncing.
  void handleReachabilityUpdate({
    required bool isPhysicallyOnline,
    required void Function(bool isOnline) onStateChanged,
    bool bypassDebounce = false,
  }) {
    _rawPhysicalOnline = isPhysicallyOnline;

    if (!isPhysicallyOnline) {
      // 0ms immediate disconnect dispatch
      _stabilizationTimer?.cancel();
      _stabilizationTimer = null;
      if (_lastEmittedOnline != false) {
        _lastEmittedOnline = false;
        if (!_simulateOffline) {
          onStateChanged(false);
        }
      }
      return;
    }

    // Recovering online
    if (bypassDebounce || policy.stabilizationDuration == Duration.zero) {
      _stabilizationTimer?.cancel();
      _stabilizationTimer = null;
      if (_lastEmittedOnline != true) {
        _lastEmittedOnline = true;
        if (!_simulateOffline) {
          onStateChanged(true);
        }
      }
      return;
    }

    // Asymmetric 3-second flap stabilization timer
    _stabilizationTimer?.cancel();
    _stabilizationTimer = Timer(policy.stabilizationDuration, () {
      if (_rawPhysicalOnline && _lastEmittedOnline != true) {
        _lastEmittedOnline = true;
        if (!_simulateOffline) {
          onStateChanged(true);
        }
      }
    });
  }

  /// Cancels active stabilization timers.
  void dispose() {
    _stabilizationTimer?.cancel();
    _stabilizationTimer = null;
  }
}
