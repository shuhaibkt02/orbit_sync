import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'sync_transport.dart';

/// Default HTTP/JSON transport implementing the Orbit wire protocol.
class HttpSyncTransport implements SyncTransport {
  final String serverUrl;
  final http.Client httpClient;
  final Future<String?> Function()? getAuthToken;
  final StreamController<void>? _remoteChangeController;

  HttpSyncTransport({
    required this.serverUrl,
    http.Client? client,
    this.getAuthToken,
  })  : httpClient = client ?? http.Client(),
        _remoteChangeController = StreamController<void>.broadcast();

  @override
  Stream<void>? get onRemoteChange => _remoteChangeController?.stream;

  /// Manually emit a remote change notification (e.g. from a WebSocket or push event).
  void notifyRemoteChange() => _remoteChangeController?.add(null);

  Future<Map<String, String>> _authHeaders() async {
    final h = <String, String>{'content-type': 'application/json'};
    if (getAuthToken != null) {
      final token = await getAuthToken!();
      if (token != null) h['authorization'] = 'Bearer $token';
    }
    return h;
  }

  @override
  Future<TransportResponse> pushBatch({
    required List<Map<String, dynamic>> mutations,
    required String idempotencyKey,
    String? chaos,
  }) async {
    try {
      final uriStr = '$serverUrl/sync/push${chaos != null ? '?chaos=$chaos' : ''}';
      final req = http.Request('POST', Uri.parse(uriStr));
      req.headers.addAll(await _authHeaders());
      req.headers['idempotency-key'] = idempotencyKey;
      req.body = jsonEncode(mutations);

      final streamed = await httpClient.send(req);
      final resp = await http.Response.fromStream(streamed);
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
  Future<TransportResponse> pushCustom({
    required String url,
    required String method,
    required String mutationId,
    required int createdAtMs,
    Map<String, dynamic>? payload,
    String? entityId,
  }) async {
    try {
      var targetUrl = url;
      if (entityId != null &&
          (method == 'PUT' || method == 'PATCH' || method == 'DELETE') &&
          !targetUrl.endsWith('/$entityId')) {
        targetUrl = '$targetUrl/$entityId';
      }

      final req = http.Request(method, Uri.parse(targetUrl));
      req.headers.addAll(await _authHeaders());
      req.headers['idempotency-key'] = mutationId;
      req.headers['x-client-mutation-id'] = mutationId;
      req.headers['x-offline-sync'] = 'true';

      final createdAtIso = DateTime.fromMillisecondsSinceEpoch(createdAtMs).toUtc().toIso8601String();
      req.headers['x-offline-created-at'] = createdAtIso;

      if (method != 'DELETE' && payload != null) {
        final bodyMap = Map<String, dynamic>.from(payload);
        if (entityId != null) bodyMap['id'] ??= entityId;
        bodyMap['_offline_meta'] = {
          'is_offline': true,
          'offline_created_at': createdAtIso,
          'mutation_id': mutationId,
        };
        req.body = jsonEncode(bodyMap);
      }

      final streamed = await httpClient.send(req);
      final resp = await http.Response.fromStream(streamed);
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
  Future<TransportResponse> pull({
    required int sinceCursor,
    required int limit,
    Map<String, dynamic>? scopeFilter,
    bool snapshot = false,
    String? chaos,
  }) async {
    try {
      var uriStr = '$serverUrl/sync/pull?limit=$limit';
      if (snapshot) {
        uriStr += '&snapshot=true';
      } else {
        uriStr += '&since=$sinceCursor';
      }
      if (chaos != null) uriStr += '&chaos=$chaos';
      if (scopeFilter != null) {
        uriStr += '&scope=${Uri.encodeComponent(jsonEncode(scopeFilter))}';
      }

      final req = http.Request('GET', Uri.parse(uriStr));
      if (getAuthToken != null) {
        final token = await getAuthToken!();
        if (token != null) req.headers['authorization'] = 'Bearer $token';
      }

      final streamed = await httpClient.send(req);
      final resp = await http.Response.fromStream(streamed);
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
  void dispose() {
    _remoteChangeController?.close();
  }
}
