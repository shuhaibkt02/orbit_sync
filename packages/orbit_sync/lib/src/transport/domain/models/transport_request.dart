/// Uniform wire-level request representation for sync transports.
class TransportRequest {
  final Uri uri;
  final String method;
  final Map<String, String> headers;
  final String? body;
  final Duration connectTimeout;
  final Duration readTimeout;
  final String? mutationId;

  const TransportRequest({
    required this.uri,
    required this.method,
    this.headers = const {},
    this.body,
    this.connectTimeout = const Duration(seconds: 3),
    this.readTimeout = const Duration(seconds: 15),
    this.mutationId,
  });

  @override
  String toString() =>
      'TransportRequest(method: $method, uri: $uri, mutationId: $mutationId, bodyLen: ${body?.length ?? 0})';
}
