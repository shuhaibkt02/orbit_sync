/// Physical or logical network interface types.
enum NetworkConnectionType {
  wifi,
  cellular,
  ethernet,
  bluetooth,
  vpn,
  none,
  unknown;

  /// True if connection is a local physical Wi-Fi link.
  bool get isWifi => this == NetworkConnectionType.wifi;

  /// True if connection is a mobile cellular link.
  bool get isCellular => this == NetworkConnectionType.cellular;

  /// True if there is no physical network interface connected.
  bool get isDisconnected => this == NetworkConnectionType.none;
}
