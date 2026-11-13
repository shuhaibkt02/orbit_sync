import 'dart:async';
import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import 'domain/interfaces/sync_http_adapter.dart';
import 'domain/models/transport_response.dart';
import 'domain/policies/payload_sanitizer.dart' as sanitizer;
import 'infrastructure/dio_http_adapter.dart';
import 'infrastructure/http_sync_transport.dart';
import 'infrastructure/in_memory_sync_transport.dart';

export 'domain/interfaces/sync_http_adapter.dart';
export 'domain/models/transport_request.dart';
export 'domain/models/transport_response.dart';
export 'domain/policies/payload_sanitizer.dart';
export 'domain/policies/retry_after_parser.dart';
export 'infrastructure/default_http_adapter.dart';
export 'infrastructure/dio_http_adapter.dart';
export 'infrastructure/http_sync_transport.dart';
export 'infrastructure/in_memory_sync_transport.dart';

/// Single source of truth for transport wire boundaries in Orbit.
abstract interface class SyncTransport {
  /// Pushes a batch of mutations to the remote push endpoint.
  Future<TransportResponse> pushBatch({
    required List<Map<String, dynamic>> mutations,
    required String idempotencyKey,
    String? chaos,
  });

  /// Pushes a single mutation with clean domain payload (zero metadata pollution).
  Future<TransportResponse> pushCustom({
    required String url,
    required String method,
    required String mutationId,
    required int createdAtMs,
    Map<String, dynamic>? payload,
    String? entityId,
    Map<String, String>? headers,
  });

  /// Binary Multipart Streaming (Photos, PDFs, Signatures) directly from disk path.
  ///
  /// Streams binary chunks from [filePath] into the HTTP socket without loading full file bytes into RAM.
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

  /// Convenience utility strictly stripping all internal sync and offline flags
  /// (`_sync_`, `_offline_`, `expires_at`, `updated_at`, `_base_snapshot_json`).
  static Map<String, dynamic> sanitizePayload(Map<String, dynamic> payload) =>
      sanitizer.sanitizePayload(payload);

  /// 1. Standard REST / HTTP Transport (Pure Dart package:http)
  factory SyncTransport.http({
    String? baseUrl,
    SyncHttpAdapter? client,
    http.Client? httpClient,
    Future<String?> Function()? getAuthToken,
    Duration connectTimeout = const Duration(seconds: 3),
    Duration readTimeout = const Duration(seconds: 10),
    String pushPath = 'sync/push',
    String pullPath = 'sync/pull',
    bool autoInjectIdempotencyKey = false,
  }) =>
      HttpSyncTransport(
        baseUrl: baseUrl ?? '',
        adapter: client,
        client: httpClient,
        getAuthToken: getAuthToken,
        connectTimeout: connectTimeout,
        readTimeout: readTimeout,
        pushPath: pushPath,
        pullPath: pullPath,
        autoInjectIdempotencyKey: autoInjectIdempotencyKey,
      );

  /// 2. Enterprise REST / HTTP Transport powered by [Dio]
  factory SyncTransport.dio({
    String? baseUrl,
    Dio? dio,
    Future<String?> Function()? getAuthToken,
    Duration connectTimeout = const Duration(seconds: 3),
    Duration readTimeout = const Duration(seconds: 15),
    String pushPath = 'sync/push',
    String pullPath = 'sync/pull',
    bool autoInjectIdempotencyKey = true,
  }) {
    final effectiveDio = dio ??
        Dio(
          BaseOptions(
            connectTimeout: connectTimeout,
            receiveTimeout: readTimeout,
          ),
        );
    final effectiveBase = baseUrl ??
        (effectiveDio.options.baseUrl.isNotEmpty
            ? effectiveDio.options.baseUrl
            : '');
    return HttpSyncTransport(
      baseUrl: effectiveBase,
      adapter: DioHttpAdapter(dio: effectiveDio),
      getAuthToken: getAuthToken,
      connectTimeout: connectTimeout,
      readTimeout: readTimeout,
      pushPath: pushPath,
      pullPath: pullPath,
      autoInjectIdempotencyKey: autoInjectIdempotencyKey,
    );
  }

  /// 3. In-Memory Mock for instant socket-free unit tests
  factory SyncTransport.inMemory({
    int pushStatusCode = 200,
    String pushResponseBody = '{"status":"ok"}',
    int pullStatusCode = 200,
    dynamic pushError,
    dynamic pullError,
    Duration simulatedLatency = Duration.zero,
    List<Map<String, dynamic>> cannedPullChanges = const [],
    int pullNextCursor = 0,
  }) =>
      InMemorySyncTransport(
        pushStatusCode: pushStatusCode,
        pushResponseBody: pushResponseBody,
        pullStatusCode: pullStatusCode,
        pushError: pushError,
        pullError: pullError,
        simulatedLatency: simulatedLatency,
        cannedPullChanges: cannedPullChanges,
        pullNextCursor: pullNextCursor,
      );
}
