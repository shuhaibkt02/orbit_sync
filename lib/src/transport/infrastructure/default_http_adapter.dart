import 'dart:async';
import 'package:http/http.dart' as http;
import '../domain/interfaces/sync_http_adapter.dart';
import '../domain/models/transport_request.dart';
import '../domain/models/transport_response.dart';

/// Pure Dart HTTP adapter with split-timeout anatomy (3s connect, 10s transfer)
/// preventing zombie sockets from hanging outbox synchronization.
class DefaultHttpAdapter implements SyncHttpAdapter {
  final http.Client _client;
  final bool _isOwned;

  DefaultHttpAdapter({http.Client? client})
      : _client = client ?? http.Client(),
        _isOwned = client == null;

  /// Underlying HTTP client instance.
  http.Client get client => _client;

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    try {
      final req = http.Request(request.method, request.uri);
      req.headers.addAll(request.headers);
      if (request.body != null) {
        req.body = request.body!;
      }

      // 1. Enforce Connect Timeout (Handshake & Stream Header initialization)
      final streamed = await _client.send(req).timeout(
            request.connectTimeout,
            onTimeout: () => throw TimeoutException(
              'Connect timeout after ${request.connectTimeout.inSeconds}s',
            ),
          );

      // 2. Enforce Read / Transfer Timeout (Body payload streaming)
      final resp = await http.Response.fromStream(streamed).timeout(
        request.readTimeout,
        onTimeout: () => throw TimeoutException(
          'Read timeout after ${request.readTimeout.inSeconds}s',
        ),
      );

      return TransportResponse(
        statusCode: resp.statusCode,
        body: resp.body,
        headers: resp.headers,
      );
    } catch (e) {
      return TransportResponse(statusCode: 0, error: e);
    }
  }

  @override
  Future<TransportResponse> pushMultipart({
    required Uri uri,
    String method = 'POST',
    required String fieldName,
    required String filePath,
    String? fileName,
    String? mimeType,
    Map<String, dynamic>? extraFields,
    Map<String, String>? headers,
    Duration? timeout,
    void Function(int sent, int total)? onSendProgress,
  }) async {
    return TransportResponse(
      statusCode: 0,
      error: UnsupportedError(
          'pushMultipart is not supported by DefaultHttpAdapter. Use DioHttpAdapter.'),
    );
  }

  @override
  void dispose() {
    if (_isOwned) {
      _client.close();
    }
  }
}
