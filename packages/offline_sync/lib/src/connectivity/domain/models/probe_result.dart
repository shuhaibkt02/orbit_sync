/// Represents the concrete outcome of a network reachability probe.
class ProbeResult {
  final bool isOnline;
  final bool isCaptivePortal;
  final int? statusCode;
  final Uri? redirectUrl;
  final int latencyMs;
  final String? errorMessage;

  const ProbeResult({
    required this.isOnline,
    this.isCaptivePortal = false,
    this.statusCode,
    this.redirectUrl,
    this.latencyMs = 0,
    this.errorMessage,
  });

  /// Successfully reached target host or canary probe.
  factory ProbeResult.online({
    int? statusCode,
    int latencyMs = 0,
  }) =>
      ProbeResult(
        isOnline: true,
        statusCode: statusCode,
        latencyMs: latencyMs,
      );

  /// Host unreachable due to socket timeout, DNS failure, or packet drop.
  factory ProbeResult.unreachable({
    String? errorMessage,
    int latencyMs = 0,
  }) =>
      ProbeResult(
        isOnline: false,
        latencyMs: latencyMs,
        errorMessage: errorMessage,
      );

  /// Traffic intercepted by a Wi-Fi captive portal / login splash screen.
  factory ProbeResult.captivePortal({
    Uri? redirectUrl,
    int latencyMs = 0,
    String? errorMessage,
  }) =>
      ProbeResult(
        isOnline: false,
        isCaptivePortal: true,
        redirectUrl: redirectUrl,
        latencyMs: latencyMs,
        errorMessage: errorMessage,
      );

  @override
  String toString() =>
      'ProbeResult(isOnline: $isOnline, code: $statusCode, captive: $isCaptivePortal, latency: ${latencyMs}ms)';
}
