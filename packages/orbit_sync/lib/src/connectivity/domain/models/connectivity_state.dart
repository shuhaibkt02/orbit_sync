import 'network_connection_type.dart';

/// Immutable snapshot of device network reachability and policy state.
class ConnectivityState {
  final bool isOnline;
  final NetworkConnectionType type;
  final bool isMetered;
  final bool isCaptivePortal;
  final DateTime timestamp;

  const ConnectivityState({
    required this.isOnline,
    this.type = NetworkConnectionType.unknown,
    this.isMetered = false,
    this.isCaptivePortal = false,
    required this.timestamp,
  });

  /// Offline state constructor.
  factory ConnectivityState.offline({
    bool isCaptivePortal = false,
    NetworkConnectionType type = NetworkConnectionType.none,
  }) =>
      ConnectivityState(
        isOnline: false,
        type: type,
        isMetered: false,
        isCaptivePortal: isCaptivePortal,
        timestamp: DateTime.now(),
      );

  /// Online state constructor.
  factory ConnectivityState.online({
    NetworkConnectionType type = NetworkConnectionType.wifi,
    bool isMetered = false,
  }) =>
      ConnectivityState(
        isOnline: true,
        type: type,
        isMetered: isMetered,
        isCaptivePortal: false,
        timestamp: DateTime.now(),
      );

  ConnectivityState copyWith({
    bool? isOnline,
    NetworkConnectionType? type,
    bool? isMetered,
    bool? isCaptivePortal,
    DateTime? timestamp,
  }) =>
      ConnectivityState(
        isOnline: isOnline ?? this.isOnline,
        type: type ?? this.type,
        isMetered: isMetered ?? this.isMetered,
        isCaptivePortal: isCaptivePortal ?? this.isCaptivePortal,
        timestamp: timestamp ?? this.timestamp,
      );

  @override
  String toString() =>
      'ConnectivityState(online: $isOnline, type: $type, metered: $isMetered, captive: $isCaptivePortal)';
}
