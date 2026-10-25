import 'dart:async';

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

  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}

/// Abstract transport boundary separating local consensus from the transmission wire.
abstract interface class SyncTransport {
  /// Pushes a batch of mutations to the remote push endpoint.
  Future<TransportResponse> pushBatch({
    required List<Map<String, dynamic>> mutations,
    required String idempotencyKey,
    String? chaos,
  });

  /// Pushes a single mutation to a custom entity endpoint URL.
  Future<TransportResponse> pushCustom({
    required String url,
    required String method,
    required String mutationId,
    required int createdAtMs,
    Map<String, dynamic>? payload,
    String? entityId,
  });

  /// Pulls a delta page from the remote pull endpoint.
  Future<TransportResponse> pull({
    required int sinceCursor,
    required int limit,
    Map<String, dynamic>? scopeFilter,
    bool snapshot = false,
    String? chaos,
  });

  /// Optional stream emitted when the remote server signals new changes.
  Stream<void>? get onRemoteChange => null;

  /// Closes underlying connections or resources.
  void dispose() {}
}
