import 'dart:async';
import '../domain/interfaces/i_network_type_provider.dart';
import '../domain/models/network_connection_type.dart';

/// Pure Dart cross-platform default network type provider.
/// Defaults to [NetworkConnectionType.unknown] and [isMetered] = false.
/// Host apps can inject native connectivity plugins without coupling offline_sync core.
class DefaultNetworkTypeProvider implements INetworkTypeProvider {
  final StreamController<NetworkConnectionType> _controller =
      StreamController<NetworkConnectionType>.broadcast();

  NetworkConnectionType _currentType = NetworkConnectionType.unknown;
  bool _isMetered = false;

  @override
  NetworkConnectionType get currentType => _currentType;

  @override
  bool get isMetered => _isMetered;

  @override
  Stream<NetworkConnectionType> get onTypeChanged => _controller.stream;

  /// Manually updates connection type (useful for testing or platform bridge).
  void setConnectionType(NetworkConnectionType type, {bool? isMetered}) {
    _currentType = type;
    _isMetered = isMetered ?? type.isCellular;
    _controller.add(type);
  }

  @override
  void dispose() {
    _controller.close();
  }
}
