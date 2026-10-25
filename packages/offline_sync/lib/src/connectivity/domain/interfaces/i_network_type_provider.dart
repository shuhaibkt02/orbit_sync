import '../models/network_connection_type.dart';

/// Strategy contract for detecting device interface type (Wi-Fi, Cellular, etc.)
abstract interface class INetworkTypeProvider {
  /// Current physical or logical network type.
  NetworkConnectionType get currentType;

  /// True if current network is metered (e.g. cellular).
  bool get isMetered;

  /// Stream of connection type changes.
  Stream<NetworkConnectionType> get onTypeChanged;

  /// Releases resources.
  void dispose();
}
