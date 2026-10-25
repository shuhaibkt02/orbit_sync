/// Discrete raw response from a remote sync transport.
class TransportResponse {
  final int statusCode;
  final String body;
  final Map<String, String> headers;
  final dynamic error;

  const TransportResponse({
    required this.statusCode,
    this.body = '',
    this.headers = const {},
    this.error,
  });

  /// True if HTTP status code is within 2xx range and error is null.
  bool get isSuccess => statusCode >= 200 && statusCode < 300 && error == null;

  /// True if request failed due to local network drop, timeout, or socket error.
  bool get isNetworkError => statusCode == 0 || error != null;

  @override
  String toString() =>
      'TransportResponse(status: $statusCode, bodyLen: ${body.length}, err: $error)';
}
