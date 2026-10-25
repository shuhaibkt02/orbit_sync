import 'package:http/http.dart' as http;
import 'domain/interfaces/i_sync_transport.dart';
import 'domain/interfaces/sync_http_adapter.dart';
import 'infrastructure/http_sync_transport.dart';
import 'infrastructure/in_memory_sync_transport.dart';

export 'domain/interfaces/i_sync_transport.dart';
export 'domain/interfaces/sync_http_adapter.dart';
export 'domain/models/transport_request.dart';
export 'domain/models/transport_response.dart';
export 'domain/policies/retry_after_parser.dart';
export 'infrastructure/default_http_adapter.dart';
export 'infrastructure/http_sync_transport.dart';
export 'infrastructure/in_memory_sync_transport.dart';

/// Public transport boundary separating local consensus from transmission wires.
abstract interface class SyncTransport implements ISyncTransport {
  /// 1. v1.0 Core: Standard REST / HTTP Transport
  factory SyncTransport.http({
    required String serverUrl,
    SyncHttpAdapter? client,
    http.Client? httpClient,
    Future<String?> Function()? getAuthToken,
    Duration connectTimeout = const Duration(seconds: 3),
    Duration readTimeout = const Duration(seconds: 10),
  }) =>
      HttpSyncTransport(
        serverUrl: serverUrl,
        adapter: client,
        client: httpClient,
        getAuthToken: getAuthToken,
        connectTimeout: connectTimeout,
        readTimeout: readTimeout,
      );

  /// 2. v1.0 Core: In-Memory Mock for instant socket-free unit tests
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

  /// 3. Roadmap v1.1: Real-Time WebSockets
  static SyncTransport webSocket({required String url}) =>
      throw UnsupportedError(
        'WebSocket transport is planned for Orbit v1.1. Track progress at https://github.com/orbit-sync/orbit/issues/websocket',
      );

  /// 4. Roadmap v1.2: High-Performance gRPC Protobuf
  static SyncTransport grpc({required String host, required int port}) =>
      throw UnsupportedError(
        'gRPC transport is planned for Orbit v1.2. Track progress at https://github.com/orbit-sync/orbit/issues/grpc',
      );

  /// 5. Roadmap v1.3: GraphQL
  static SyncTransport graphql({required String endpoint}) =>
      throw UnsupportedError(
        'GraphQL transport is planned for Orbit v1.3. Track progress at https://github.com/orbit-sync/orbit/issues/graphql',
      );
}
