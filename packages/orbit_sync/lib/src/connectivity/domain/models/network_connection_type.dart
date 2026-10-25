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

  /// True if network link is classified as metered / mobile data.
  bool get isMetered =>
      this == NetworkConnectionType.cellular ||
      this == NetworkConnectionType.bluetooth;

  /// True if there is no physical network interface connected.
  bool get isDisconnected => this == NetworkConnectionType.none;
}
