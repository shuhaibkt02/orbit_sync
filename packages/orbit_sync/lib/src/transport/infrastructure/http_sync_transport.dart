import 'dart:async';
import 'dart:convert';
import 'package:collection/collection.dart';
import 'package:http/http.dart' as http;
import '../sync_transport.dart';
import '../domain/policies/payload_sanitizer.dart' as sanitizer;

/// Clean Architecture REST wire protocol transport for Orbit.
/// Guarantees zero metadata pollution in request bodies and automatic idempotency key injection.
class HttpSyncTransport implements SyncTransport {
  String baseUrl;
  String pushPath;
  String pullPath;
  final bool autoInjectIdempotencyKey;

  final SyncHttpAdapter _adapter;
  Future<String?> Function()? getAuthToken;
  final Duration connectTimeout;
  final Duration readTimeout;
  final StreamController<void> _remoteChangeController =
      StreamController<void>.broadcast();

  HttpSyncTransport({
    String? baseUrl,
    SyncHttpAdapter? adapter,
    http.Client? client,
    this.getAuthToken,
    this.connectTimeout = const Duration(seconds: 3),
    this.readTimeout = const Duration(seconds: 15),
    this.pushPath = 'sync/push',
    this.pullPath = 'sync/pull',
    bool? autoInjectIdempotencyKey,
  })  : baseUrl = baseUrl ?? '',
        _adapter = adapter ?? DefaultHttpAdapter(client: client),
        autoInjectIdempotencyKey = autoInjectIdempotencyKey ?? (adapter is DioHttpAdapter);

  /// Underlying HTTP adapter.
  SyncHttpAdapter get adapter => _adapter;

  /// Underlying HTTP client if running on [DefaultHttpAdapter].
  http.Client? get httpClient =>
      _adapter is DefaultHttpAdapter ? (_adapter as DefaultHttpAdapter).client : null;

  /// Helper to sanitize payloads removing internal sync and offline flags.
  static Map<String, dynamic> sanitizePayload(Map<String, dynamic> payload) =>
      sanitizer.sanitizePayload(payload);

  @override
  Stream<void> get onRemoteChange => _remoteChangeController.stream;

  void notifyRemoteChange() {
    if (!_remoteChangeController.isClosed) {
      _remoteChangeController.add(null);
    }
  }

  Future<Map<String, String>> _authHeaders() async {
    final h = CanonicalizedMap<String, String, String>((k) => k.toLowerCase());
    h['content-type'] = 'application/json';
    if (getAuthToken != null) {
      final token = await getAuthToken!();
      if (token != null && token.isNotEmpty) {
        h['Authorization'] = token.startsWith('Bearer ') ? token : 'Bearer $token';
      }
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
    final base = _joinUrl(baseUrl, pushPath);
    final uriStr = '$base${chaos != null ? '?chaos=$chaos' : ''}';
    final headers = await _authHeaders();
    headers['Idempotency-Key'] = idempotencyKey;

    final sanitizedMutations = mutations.map((m) {
      final sanitized = Map<String, dynamic>.from(m);
      if (sanitized['payload'] is Map<String, dynamic>) {
        sanitized['payload'] = sanitizer.sanitizePayload(sanitized['payload'] as Map<String, dynamic>);
      } else if (sanitized['payload'] is Map) {
        sanitized['payload'] = sanitizer.sanitizePayload(Map<String, dynamic>.from(sanitized['payload'] as Map));
      }
      return sanitized;
    }).toList();

    final request = TransportRequest(
      uri: Uri.parse(uriStr),
      method: 'POST',
      headers: headers,
      body: jsonEncode(sanitizedMutations),
      connectTimeout: connectTimeout,
      readTimeout: readTimeout,
      mutationId: idempotencyKey,
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
    Map<String, String>? headers,
  }) async {
    var targetUrl = url;
    if (entityId != null &&
        (method == 'PUT' || method == 'PATCH' || method == 'DELETE') &&
        !targetUrl.endsWith('/$entityId')) {
      targetUrl = _joinUrl(targetUrl, entityId);
    }

    final reqHeaders = await _authHeaders();
    if (headers != null) reqHeaders.addAll(headers);

    final isMutating = const {'POST', 'PUT', 'PATCH', 'DELETE'}.contains(method.toUpperCase());
    if (isMutating && autoInjectIdempotencyKey) {
      if (!reqHeaders.containsKey('Idempotency-Key')) {
        reqHeaders['Idempotency-Key'] = mutationId;
      }
    }

    // Zero Metadata Pollution: Clean domain body with strictly stripped internal flags
    String? bodyStr;
    if (method != 'DELETE' && payload != null) {
      final sanitized = sanitizer.sanitizePayload(payload);
      bodyStr = jsonEncode(sanitized);
    }

    final request = TransportRequest(
      uri: Uri.parse(targetUrl),
      method: method,
      headers: reqHeaders,
      body: bodyStr,
      connectTimeout: connectTimeout,
      readTimeout: readTimeout,
      mutationId: mutationId,
    );
    return await _adapter.send(request);
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
    var targetUri = uri;
    if (!targetUri.hasScheme && baseUrl.isNotEmpty) {
      targetUri = Uri.parse(_joinUrl(baseUrl, targetUri.toString()));
    }

    final reqHeaders = <String, String>{};
    if (getAuthToken != null) {
      final token = await getAuthToken!();
      if (token != null && token.isNotEmpty) {
        reqHeaders['Authorization'] = token.startsWith('Bearer ') ? token : 'Bearer $token';
      }
    }
    if (headers != null) {
      reqHeaders.addAll(headers);
    }

    return _adapter.pushMultipart(
      uri: targetUri,
      method: method,
      fieldName: fieldName,
      filePath: filePath,
      fileName: fileName,
      mimeType: mimeType,
      extraFields: extraFields,
      headers: reqHeaders,
      timeout: timeout,
      onSendProgress: onSendProgress,
    );
  }

  @override
  Future<TransportResponse> pull({
    required int sinceCursor,
    required int limit,
    Map<String, dynamic>? scopeFilter,
    bool snapshot = false,
    String? chaos,
  }) async {
    final base = _joinUrl(baseUrl, pullPath);
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
