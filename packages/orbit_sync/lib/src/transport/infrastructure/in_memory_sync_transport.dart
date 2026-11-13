import 'dart:async';
import 'dart:convert';
import '../sync_transport.dart';

/// Fast, deterministic in-memory mock transport for unit testing without sockets.
class InMemorySyncTransport implements SyncTransport {
  int pushStatusCode;
  String pushResponseBody;
  int pullStatusCode;
  dynamic pushError;
  dynamic pullError;
  Duration simulatedLatency;
  List<Map<String, dynamic>> cannedPullChanges;
  int pullNextCursor;

  final List<List<Map<String, dynamic>>> pushedBatches = [];
  final List<Map<String, dynamic>> customPushes = [];
  final List<Map<String, dynamic>> multipartPushes = [];
  final StreamController<void> _remoteChangeController =
      StreamController<void>.broadcast();

  InMemorySyncTransport({
    this.pushStatusCode = 200,
    this.pushResponseBody = '{"status":"ok"}',
    this.pullStatusCode = 200,
    this.pushError,
    this.pullError,
    this.simulatedLatency = Duration.zero,
    this.cannedPullChanges = const [],
    this.pullNextCursor = 0,
  });

  @override
  Stream<void> get onRemoteChange => _remoteChangeController.stream;

  void notifyRemoteChange() {
    if (!_remoteChangeController.isClosed) {
      _remoteChangeController.add(null);
    }
  }

  @override
  Future<TransportResponse> pushBatch({
    required List<Map<String, dynamic>> mutations,
    required String idempotencyKey,
    String? chaos,
  }) async {
    if (simulatedLatency > Duration.zero) await Future<void>.delayed(simulatedLatency);
    if (pushError != null) return TransportResponse(statusCode: 0, error: pushError);

    pushedBatches.add(mutations);
    return TransportResponse(statusCode: pushStatusCode, body: pushResponseBody);
  }

  @override
  Future<TransportResponse> pushCustom({
    required String url,
    required String method,
    required String mutationId,
    required int createdAtMs,
    Map<String, dynamic>? payload,
    String? entityId,
    Map<String, String>? headers,
  }) async {
    if (simulatedLatency > Duration.zero) await Future<void>.delayed(simulatedLatency);
    if (pushError != null) return TransportResponse(statusCode: 0, error: pushError);

    customPushes.add({
      'url': url,
      'method': method,
      'mutationId': mutationId,
      'createdAtMs': createdAtMs,
      'payload': payload,
      'entityId': entityId,
      'headers': headers,
    });
    return TransportResponse(statusCode: pushStatusCode, body: pushResponseBody);
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
    if (simulatedLatency > Duration.zero) await Future<void>.delayed(simulatedLatency);
    if (pushError != null) return TransportResponse(statusCode: 0, error: pushError);

    multipartPushes.add({
      'uri': uri,
      'method': method,
      'fieldName': fieldName,
      'filePath': filePath,
      'fileName': fileName,
      'mimeType': mimeType,
      'extraFields': extraFields,
      'headers': headers,
      'timeout': timeout,
    });
    return TransportResponse(statusCode: pushStatusCode, body: pushResponseBody);
  }

  @override
  Future<TransportResponse> pull({
    required int sinceCursor,
    required int limit,
    Map<String, dynamic>? scopeFilter,
    bool snapshot = false,
    String? chaos,
  }) async {
    if (simulatedLatency > Duration.zero) await Future<void>.delayed(simulatedLatency);
    if (pullError != null) return TransportResponse(statusCode: 0, error: pullError);

    final payload = {
      'changes': cannedPullChanges,
      'next_cursor': pullNextCursor,
      'has_more': false,
    };
    return TransportResponse(statusCode: pullStatusCode, body: jsonEncode(payload));
  }

  void reset() {
    pushedBatches.clear();
    customPushes.clear();
    multipartPushes.clear();
    pushStatusCode = 200;
    pushResponseBody = '{"status":"ok"}';
    pullStatusCode = 200;
    pushError = null;
    pullError = null;
  }

  @override
  void dispose() {
    _remoteChangeController.close();
  }
}
