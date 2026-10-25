import 'dart:async';
import 'package:http/http.dart' as http;
import 'domain/interfaces/i_connectivity_monitor.dart';
import 'domain/interfaces/i_network_probe.dart';
import 'domain/interfaces/i_network_type_provider.dart';
import 'domain/models/connectivity_state.dart';
import 'domain/policies/debounce_policy.dart';
import 'infrastructure/http_network_probe.dart';
import 'infrastructure/default_network_type_provider.dart';
import 'services/debounced_state_machine.dart';
import 'services/heartbeat_scheduler.dart';

export 'domain/interfaces/i_connectivity_monitor.dart';
export 'domain/interfaces/i_network_probe.dart';
export 'domain/interfaces/i_network_type_provider.dart';
export 'domain/models/connectivity_state.dart';
export 'domain/models/network_connection_type.dart';
export 'domain/models/probe_result.dart';
export 'domain/policies/network_metered_policy.dart';
export 'domain/policies/debounce_policy.dart';

/// Clean Architecture coordinator facade for Layer 3 Connectivity Sensing Layer.
/// Monitors network reachability, captive portal interception, asymmetric debouncing,
/// metered connection policies, and software-simulated offline mode.
class ConnectivityMonitor implements IConnectivityMonitor {
  final Duration timeout;
  final Duration heartbeatInterval;
  String? defaultProbeUrl;
  final Future<bool> Function()? reachabilityChecker;

  final INetworkProbe _probe;
  final INetworkTypeProvider _typeProvider;
  final DebouncedStateMachine _stateMachine;
  late final HeartbeatScheduler _heartbeatScheduler;

  final StreamController<ConnectivityState> _stateController =
      StreamController<ConnectivityState>.broadcast();
  final StreamController<bool> _boolController =
      StreamController<bool>.broadcast();

  ConnectivityState _currentState = ConnectivityState.online();

  ConnectivityMonitor({
    this.timeout = const Duration(seconds: 3),
    this.heartbeatInterval = const Duration(seconds: 30),
    this.defaultProbeUrl,
    this.reachabilityChecker,
    INetworkProbe? probe,
    INetworkTypeProvider? typeProvider,
    DebouncePolicy debouncePolicy = DebouncePolicy.standard,
    http.Client? httpClient,
  })  : _probe = probe ?? HttpNetworkProbe(client: httpClient, defaultTimeout: timeout),
        _typeProvider = typeProvider ?? DefaultNetworkTypeProvider(),
        _stateMachine = DebouncedStateMachine(policy: debouncePolicy) {
    _heartbeatScheduler = HeartbeatScheduler(
      interval: heartbeatInterval,
      onCheck: () => checkReachability(bypassDebounce: true),
    );

    _typeProvider.onTypeChanged.listen((_) {
      _publishState();
    });
  }

  @override
  ConnectivityState get state => _currentState;

  @override
  bool get isOnline => _stateMachine.isOnline;

  @override
  bool get isMetered => _typeProvider.isMetered;

  @override
  bool get simulateOffline => _stateMachine.simulateOffline;

  @override
  set simulateOffline(bool value) {
    if (_stateMachine.simulateOffline == value) return;
    _stateMachine.simulateOffline = value;
    _publishState();
  }

  @override
  Stream<ConnectivityState> get onStateChanged => _stateController.stream;

  @override
  Stream<bool> get onConnectivityChanged => _boolController.stream;

  @override
  Future<bool> checkReachability({
    String? targetUrl,
    bool bypassDebounce = false,
  }) async {
    if (simulateOffline) {
      _updatePhysicalState(isPhysicallyOnline: false, isCaptivePortal: false, bypassDebounce: true);
      return false;
    }

    if (reachabilityChecker != null) {
      try {
        final ok = await reachabilityChecker!();
        _updatePhysicalState(isPhysicallyOnline: ok, isCaptivePortal: false, bypassDebounce: bypassDebounce);
        return ok;
      } catch (_) {
        _updatePhysicalState(isPhysicallyOnline: false, isCaptivePortal: false, bypassDebounce: bypassDebounce);
        return false;
      }
    }

    final rawUrl = targetUrl ?? defaultProbeUrl;
    final Uri targetUri = (rawUrl != null && rawUrl.isNotEmpty)
        ? (rawUrl.startsWith('http://') || rawUrl.startsWith('https://') ? Uri.parse(rawUrl) : Uri.parse('http://$rawUrl'))
        : Uri.parse('http://connectivitycheck.gstatic.com/generate_204');

    final result = await _probe.probe(targetUri, timeout: timeout);

    _updatePhysicalState(
      isPhysicallyOnline: result.isOnline,
      isCaptivePortal: result.isCaptivePortal,
      bypassDebounce: bypassDebounce,
    );

    return isOnline;
  }

  void _updatePhysicalState({
    required bool isPhysicallyOnline,
    required bool isCaptivePortal,
    required bool bypassDebounce,
  }) {
    _stateMachine.handleReachabilityUpdate(
      isPhysicallyOnline: isPhysicallyOnline,
      bypassDebounce: bypassDebounce,
      onStateChanged: (online) {
        _publishState(isCaptivePortal: isCaptivePortal);
      },
    );
  }

  void _publishState({bool isCaptivePortal = false}) {
    final effectiveOnline = isOnline;
    _currentState = ConnectivityState(
      isOnline: effectiveOnline,
      type: _typeProvider.currentType,
      isMetered: _typeProvider.isMetered,
      isCaptivePortal: isCaptivePortal,
      timestamp: DateTime.now(),
    );

    _stateController.add(_currentState);
    _boolController.add(effectiveOnline);

    if (!effectiveOnline) {
      _heartbeatScheduler.start();
    } else {
      _heartbeatScheduler.stop();
    }
  }

  @override
  Future<void> notifyAppResumed() async {
    await checkReachability(bypassDebounce: true);
  }

  @override
  void dispose() {
    _heartbeatScheduler.dispose();
    _stateMachine.dispose();
    _probe.dispose();
    _typeProvider.dispose();
    _stateController.close();
    _boolController.close();
  }
}
