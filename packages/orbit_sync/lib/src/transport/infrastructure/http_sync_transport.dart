import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../sync_transport.dart';

/// Clean Architecture REST wire protocol transport for Orbit.
/// Guarantees zero metadata pollution in request bodies.
class HttpSyncTransport implements SyncTransport {
  final String serverUrl;
  final SyncHttpAdapter _adapter;
  Future<String?> Function()? getAuthToken;
  final Duration connectTimeout;
  final Duration readTimeout;
  final StreamController<void> _remoteChangeController =
      StreamController<void>.broadcast();

  HttpSyncTransport({
    required this.serverUrl,
    SyncHttpAdapter? adapter,
    http.Client? client,
    this.getAuthToken,
    this.connectTimeout = const Duration(seconds: 3),
    this.readTimeout = const Duration(seconds: 10),
  }) : _adapter = adapter ?? DefaultHttpAdapter(client: client);

  /// Underlying HTTP adapter.
  SyncHttpAdapter get adapter => _adapter;

  /// Underlying HTTP client if running on [DefaultHttpAdapter].
  http.Client? get httpClient =>
      _adapter is DefaultHttpAdapter ? (_adapter as DefaultHttpAdapter).client : null;

  @override
  Stream<void> get onRemoteChange => _remoteChangeController.stream;

  void notifyRemoteChange() {
    if (!_remoteChangeController.isClosed) {
      _remoteChangeController.add(null);
    }
  }

  Future<Map<String, String>> _authHeaders() async {
    final h = <String, String>{'content-type': 'application/json'};
    if (getAuthToken != null) {
      final token = await getAuthToken!();
      if (token != null) h['authorization'] = 'Bearer $token';
    }
    return h;
  }

  String _joinUrl(String base, String path) {
    final cleanBase = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final cleanPath = path.startsWith('/') ? path : '/$path';
    return '$cleanBase$cleanPath';
  }

  @override
  Future<TransportResponse> pushBatch({
    required List<Map<String, dynamic>> mutations,
    required String idempotencyKey,
    String? chaos,
  }) async {
    final base = _joinUrl(serverUrl, 'sync/push');
    final uriStr = '$base${chaos != null ? '?chaos=$chaos' : ''}';
    final headers = await _authHeaders();
    headers['idempotency-key'] = idempotencyKey;

    final request = TransportRequest(
      uri: Uri.parse(uriStr),
      method: 'POST',
      headers: headers,
      body: jsonEncode(mutations),
      connectTimeout: connectTimeout,
      readTimeout: readTimeout,
    );
    return await _adapter.send(request);
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
    var targetUrl = url;
    if (entityId != null &&
        (method == 'PUT' || method == 'PATCH' || method == 'DELETE')) {
      targetUrl = _joinUrl(targetUrl, entityId);
    }

    final headers = await _authHeaders();
    headers['idempotency-key'] = mutationId;
    headers['x-client-mutation-id'] = mutationId;
    headers['x-offline-sync'] = 'true';

    final createdAtIso = DateTime.fromMillisecondsSinceEpoch(createdAtMs)
        .toUtc()
        .toIso8601String();
    headers['x-offline-created-at'] = createdAtIso;

    // Zero Metadata Pollution: Clean domain body with zero _offline_meta
    String? bodyStr;
    if (method != 'DELETE' && payload != null) {
      final bodyMap = Map<String, dynamic>.from(payload);
      bodyMap.remove('_offline_meta');
      bodyMap.removeWhere((k, _) => k.startsWith('_sync_') || k.startsWith('_offline_'));
      if (entityId != null) bodyMap['id'] ??= entityId;
      bodyStr = jsonEncode(bodyMap);
    }

    final request = TransportRequest(
      uri: Uri.parse(targetUrl),
      method: method,
      headers: headers,
      body: bodyStr,
      connectTimeout: connectTimeout,
      readTimeout: readTimeout,
    );
    return await _adapter.send(request);
  }

  @override
  Future<TransportResponse> pull({
    required int sinceCursor,
    required int limit,
    Map<String, dynamic>? scopeFilter,
    bool snapshot = false,
    String? chaos,
  }) async {
    final base = _joinUrl(serverUrl, 'sync/pull');
    var uriStr = '$base?limit=$limit';
    if (snapshot) {
      uriStr += '&snapshot=true';
    } else {
      uriStr += '&since=$sinceCursor';
    }
    if (chaos != null) uriStr += '&chaos=$chaos';
    if (scopeFilter != null) {
      uriStr += '&scope=${Uri.encodeComponent(jsonEncode(scopeFilter))}';
    }

    final headers = await _authHeaders();
    final request = TransportRequest(
      uri: Uri.parse(uriStr),
      method: 'GET',
      headers: headers,
      connectTimeout: connectTimeout,
      readTimeout: readTimeout,
    );
    return await _adapter.send(request);
  }

  @override
  void dispose() {
    _remoteChangeController.close();
    _adapter.dispose();
  }
}
