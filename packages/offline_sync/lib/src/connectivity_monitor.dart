import 'dart:async';
import 'dart:io';

/// Battery-friendly connectivity and dead-zone reachability monitor.
/// Uses lightweight socket handshakes with strict timeouts (3s) to detect
/// true internet reachability without third-party platform channels.
class ConnectivityMonitor {
  final Duration timeout;
  final Duration heartbeatInterval;
  String? defaultProbeUrl;

  bool _isOnline = true;
  Timer? _heartbeatTimer;
  final StreamController<bool> _controller = StreamController<bool>.broadcast();

  ConnectivityMonitor({
    this.timeout = const Duration(seconds: 3),
    this.heartbeatInterval = const Duration(seconds: 30),
    this.defaultProbeUrl,
  });

  /// Current reachability status.
  bool get isOnline => _isOnline;

  /// Stream of connectivity transitions (true = online, false = dead zone).
  Stream<bool> get onConnectivityChanged => _controller.stream;

  /// Probes the target host with a strict [timeout].
  /// Returns true if reachable, false if dead zone or network drop.
  Future<bool> checkReachability({String? targetUrl}) async {
    final rawUrl = targetUrl ?? defaultProbeUrl;
    try {
      if (rawUrl != null && rawUrl.isNotEmpty) {
        final uri = Uri.parse(rawUrl);
        final host = uri.host.isNotEmpty ? uri.host : rawUrl;
        final port = uri.hasPort ? uri.port : (uri.scheme == 'http' ? 80 : 443);
        final socket = await Socket.connect(host, port, timeout: timeout);
        socket.destroy();
      } else {
        // Fallback canary probe
        final socket = await Socket.connect('1.1.1.1', 53, timeout: timeout);
        socket.destroy();
      }
      _setOnline(true);
      return true;
    } catch (_) {
      _setOnline(false);
      return false;
    }
  }

  void _setOnline(bool online) {
    if (_isOnline != online) {
      _isOnline = online;
      _controller.add(online);

      if (!online) {
        _startHeartbeat();
      } else {
        _stopHeartbeat();
      }
    }
  }

  /// Starts periodic low-cost probing while in a dead zone until signal returns.
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) async {
      final reachable = await checkReachability();
      if (reachable) {
        _stopHeartbeat();
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// Closes internal controllers and cancels background timers.
  void dispose() {
    _stopHeartbeat();
    _controller.close();
  }
}
