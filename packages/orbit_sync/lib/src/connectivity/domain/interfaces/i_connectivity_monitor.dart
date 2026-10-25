import '../models/connectivity_state.dart';

/// Primary contract for Layer 3 Connectivity Sensing Layer.
abstract interface class IConnectivityMonitor {
  /// Current reachability and network snapshot.
  ConnectivityState get state;

  /// True if device has verified end-to-end internet connectivity.
  bool get isOnline;

  /// True if current connection is metered.
  bool get isMetered;

  /// Software-simulated offline mode for QA and CI/CD testing.
  bool get simulateOffline;
  set simulateOffline(bool value);

  /// Broadcast stream of rich [ConnectivityState] updates.
  Stream<ConnectivityState> get onStateChanged;

  /// Legacy boolean stream for backward compatibility (true = online).
  Stream<bool> get onConnectivityChanged;

  /// Probes network reachability with optional debounce bypass.
  Future<bool> checkReachability({String? targetUrl, bool bypassDebounce = false});

  /// Zero-delay wakeup hook for OS app resume / foregrounding events.
  Future<void> notifyAppResumed();

  /// Releases stream controllers and background heartbeat timers.
  void dispose();
}
