import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';

void main() {
  group('Ticket 07: Dio as First-Class Default Adapter & Wire Sanitization',
      () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('orbit_dio_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    group('1. Wire Sanitization (sanitizePayload)', () {
      test(
          'strictly strips all internal flags (_sync_, _offline_, expires_at, updated_at, _base_snapshot_json)',
          () {
        final dirtyPayload = {
          'id': 'rec-123',
          'title': 'Enterprise Task',
          'amount': 250.75,
          'created_at': 1700000000,
          // Internal flags to be stripped:
          '_sync_status': 'pending',
          '_sync_version': 3,
          '_sync_retries': 0,
          '_offline_meta': {'client': 'flutter-app', 'device': 'macos'},
          '_offline_queued_at': 1700000005,
          'expires_at': 1700003600,
          'updated_at': 1700000010,
          '_base_snapshot_json': '{"id":"rec-123","title":"Old Title"}',
          '_base_snapshot': {'id': 'rec-123'},
        };

        final clean = sanitizePayload(dirtyPayload);

        // Assert domain fields are preserved
        expect(clean['id'], equals('rec-123'));
        expect(clean['title'], equals('Enterprise Task'));
        expect(clean['amount'], equals(250.75));
        expect(clean['created_at'], equals(1700000000));

        // Assert internal flags are completely stripped
        expect(clean.containsKey('_sync_status'), isFalse);
        expect(clean.containsKey('_sync_version'), isFalse);
        expect(clean.containsKey('_sync_retries'), isFalse);
        expect(clean.containsKey('_offline_meta'), isFalse);
        expect(clean.containsKey('_offline_queued_at'), isFalse);
        expect(clean.containsKey('expires_at'), isFalse);
        expect(clean.containsKey('updated_at'), isFalse);
        expect(clean.containsKey('_base_snapshot_json'), isFalse);
        expect(clean.containsKey('_base_snapshot'), isFalse);
      });

      test('handles case-insensitivity when stripping internal flags', () {
        final dirtyPayload = {
          'name': 'Widget',
          '_SYNC_STATUS': 'failed',
          '_OFFLINE_META': 'strip-me',
          'EXPIRES_AT': 999999999,
          'UPDATED_AT': 888888888,
          '_BASE_SNAPSHOT_JSON': '{}',
        };

        final clean = sanitizePayload(dirtyPayload);

        expect(clean['name'], equals('Widget'));
        expect(clean.containsKey('_SYNC_STATUS'), isFalse);
        expect(clean.containsKey('_OFFLINE_META'), isFalse);
        expect(clean.containsKey('EXPIRES_AT'), isFalse);
        expect(clean.containsKey('UPDATED_AT'), isFalse);
        expect(clean.containsKey('_BASE_SNAPSHOT_JSON'), isFalse);
      });

      test('recursively sanitizes nested maps and lists of maps', () {
        final nestedDirty = {
          'id': 'parent-1',
          'metadata': {
            'author': 'Alice',
            '_sync_flag': true,
            'expires_at': 12345,
            'settings': {
              'theme': 'dark',
              'updated_at': 67890,
            },
          },
          'items': [
            {'item_id': 101, 'name': 'Item 1', '_offline_tag': 'skip'},
            {'item_id': 102, 'name': 'Item 2', 'updated_at': 999},
          ],
        };

        final clean = sanitizePayload(nestedDirty);

        expect(clean['id'], equals('parent-1'));
        final meta = clean['metadata'] as Map<String, dynamic>;
        expect(meta['author'], equals('Alice'));
        expect(meta.containsKey('_sync_flag'), isFalse);
        expect(meta.containsKey('expires_at'), isFalse);
        final settings = meta['settings'] as Map<String, dynamic>;
        expect(settings['theme'], equals('dark'));
        expect(settings.containsKey('updated_at'), isFalse);

        final items = clean['items'] as List;
        expect(items.length, equals(2));
        expect((items[0] as Map)['name'], equals('Item 1'));
        expect((items[0] as Map).containsKey('_offline_tag'), isFalse);
        expect((items[1] as Map)['name'], equals('Item 2'));
        expect((items[1] as Map).containsKey('updated_at'), isFalse);
      });

      test('accessible via DioHttpAdapter and SyncTransport class helpers', () {
        final sample = {'title': 'Sample', '_sync_test': 1, 'updated_at': 2};
        final cleanViaDio = DioHttpAdapter.sanitizePayload(sample);
        final cleanViaTransport = SyncTransport.sanitizePayload(sample);

        expect(cleanViaDio, equals({'title': 'Sample'}));
        expect(cleanViaTransport, equals({'title': 'Sample'}));
      });
    });

    group('2. DioHttpAdapter Construction & Split Timeout Anatomy', () {
      test(
          'fallback internal Dio instance has standard split timeouts (3s connect, 15s receive)',
          () {
        final adapter = DioHttpAdapter();
        expect(adapter.dio.options.connectTimeout,
            equals(const Duration(seconds: 3)));
        expect(adapter.dio.options.receiveTimeout,
            equals(const Duration(seconds: 15)));
        adapter.dispose();
      });

      test(
          'adopts host pre-configured Dio instance without overriding custom options',
          () {
        final hostDio = Dio(
          BaseOptions(
            baseUrl: 'https://custom.corp.net',
            connectTimeout: const Duration(seconds: 7),
            receiveTimeout: const Duration(seconds: 25),
          ),
        );
        final adapter = DioHttpAdapter(dio: hostDio);

        expect(adapter.dio, same(hostDio));
        expect(adapter.dio.options.baseUrl, equals('https://custom.corp.net'));
        expect(adapter.dio.options.connectTimeout,
            equals(const Duration(seconds: 7)));
        expect(adapter.dio.options.receiveTimeout,
            equals(const Duration(seconds: 25)));

        // Disposing does not close the host app's owned Dio instance
        adapter.dispose();
        expect(hostDio.httpClientAdapter, isNotNull);
      });
    });

    group('3. OrbitClient.initialize Integration & Adapter Selection', () {
      test(
          'defaults to DioHttpAdapter when dio is omitted and no custom transport is provided',
          () async {
        final dbPath = '${tempDir.path}/dio_default.db';
        final client = await OrbitClient.initialize(
          databasePath: dbPath,
          baseUrl: 'https://api.example.com',
        );

        expect(client.transport, isA<HttpSyncTransport>());
        final httpTransport = client.transport as HttpSyncTransport;
        expect(httpTransport.adapter, isA<DioHttpAdapter>());
        final dioAdapter = httpTransport.adapter as DioHttpAdapter;
        expect(dioAdapter.dio.options.connectTimeout,
            equals(const Duration(seconds: 3)));
        expect(dioAdapter.dio.options.receiveTimeout,
            equals(const Duration(seconds: 15)));

        await client.close();
      });

      test(
          'accepts host pre-configured Dio client and uses it as transport engine',
          () async {
        final dbPath = '${tempDir.path}/dio_custom.db';
        final hostDio = Dio(BaseOptions(baseUrl: 'https://api.enterprise.com'));
        bool interceptorCalled = false;
        hostDio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              interceptorCalled = true;
              return handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: '{"status":"ok"}',
                ),
              );
            },
          ),
        );

        final client = await OrbitClient.initialize(
          databasePath: dbPath,
          dio: hostDio,
        );

        expect(client.transport, isA<HttpSyncTransport>());
        final httpTransport = client.transport as HttpSyncTransport;
        expect(httpTransport.adapter, isA<DioHttpAdapter>());
        final dioAdapter = httpTransport.adapter as DioHttpAdapter;
        expect(dioAdapter.dio, same(hostDio));

        // Trigger pushCustom
        final res = await httpTransport.pushCustom(
          url: 'https://api.enterprise.com/items',
          method: 'POST',
          mutationId: 'mut-host-1',
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
          payload: {'name': 'Box'},
        );

        expect(res.isSuccess, isTrue);
        expect(interceptorCalled, isTrue);

        await client.close();
      });

      test(
          'preserves DefaultHttpAdapter (package:http) when explicitly configured via httpClient',
          () async {
        final dbPath = '${tempDir.path}/http_default.db';
        final mockHttpClient = http.Client();
        final client = await OrbitClient.initialize(
          databasePath: dbPath,
          baseUrl: 'https://api.example.com',
          httpClient: mockHttpClient,
        );

        expect(client.transport, isA<HttpSyncTransport>());
        final httpTransport = client.transport as HttpSyncTransport;
        expect(httpTransport.adapter, isA<DefaultHttpAdapter>());

        await client.close();
        mockHttpClient.close();
      });

      test('preserves custom transport when explicitly provided', () async {
        final dbPath = '${tempDir.path}/custom_transport.db';
        final inMemory = SyncTransport.inMemory();
        final client = await OrbitClient.initialize(
          databasePath: dbPath,
          transport: inMemory,
        );

        expect(client.transport, same(inMemory));

        await client.close();
      });
    });

    group('4. Automatic Idempotency-Key & Authorization Injection', () {
      test(
          'injects Idempotency-Key and Authorization on mutating HTTP calls (POST, PUT, PATCH, DELETE)',
          () async {
        final dio = Dio();
        final capturedRequests = <RequestOptions>[];

        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              capturedRequests.add(options);
              return handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: '{"result":"success"}',
                ),
              );
            },
          ),
        );

        final transport = SyncTransport.dio(
          baseUrl: 'https://api.test.com',
          dio: dio,
          getAuthToken: () async => 'jwt-token-xyz',
        );

        // 1. POST (Mutating)
        await transport.pushCustom(
          url: 'https://api.test.com/orders',
          method: 'POST',
          mutationId: 'mut-post-1',
          createdAtMs: 1700000000,
          payload: {'product': 'Laptop'},
        );
        expect(capturedRequests.last.headers['Idempotency-Key'],
            equals('mut-post-1'));
        expect(capturedRequests.last.headers['Authorization'],
            equals('Bearer jwt-token-xyz'));

        // 2. PUT (Mutating)
        await transport.pushCustom(
          url: 'https://api.test.com/orders/ord-99',
          method: 'PUT',
          mutationId: 'mut-put-2',
          createdAtMs: 1700000001,
          payload: {'product': 'Laptop Pro'},
        );
        expect(capturedRequests.last.headers['Idempotency-Key'],
            equals('mut-put-2'));
        expect(capturedRequests.last.headers['Authorization'],
            equals('Bearer jwt-token-xyz'));

        // 3. PATCH (Mutating)
        await transport.pushCustom(
          url: 'https://api.test.com/orders/ord-99',
          method: 'PATCH',
          mutationId: 'mut-patch-3',
          createdAtMs: 1700000002,
          payload: {'status': 'shipped'},
        );
        expect(capturedRequests.last.headers['Idempotency-Key'],
            equals('mut-patch-3'));
        expect(capturedRequests.last.headers['Authorization'],
            equals('Bearer jwt-token-xyz'));

        // 4. DELETE (Mutating)
        await transport.pushCustom(
          url: 'https://api.test.com/orders/ord-99',
          method: 'DELETE',
          mutationId: 'mut-del-4',
          createdAtMs: 1700000003,
        );
        expect(capturedRequests.last.headers['Idempotency-Key'],
            equals('mut-del-4'));
        expect(capturedRequests.last.headers['Authorization'],
            equals('Bearer jwt-token-xyz'));

        // 5. Batch Push (Mutating POST)
        await transport.pushBatch(
          mutations: [
            {
              'entity': 'orders',
              'id': 'ord-100',
              'op': 'create',
              'payload': {'item': 'Desk'}
            },
          ],
          idempotencyKey: 'batch-mut-999',
        );
        expect(capturedRequests.last.headers['Idempotency-Key'],
            equals('batch-mut-999'));
        expect(capturedRequests.last.headers['Authorization'],
            equals('Bearer jwt-token-xyz'));

        // 6. GET / Pull (Non-mutating: MUST NOT inject Idempotency-Key)
        await transport.pull(sinceCursor: 0, limit: 10);
        expect(capturedRequests.last.headers.containsKey('Idempotency-Key'),
            isFalse);
        expect(capturedRequests.last.headers['Authorization'],
            equals('Bearer jwt-token-xyz'));

        transport.dispose();
      });

      test('preserves developer-provided custom Idempotency-Key and headers',
          () async {
        final dio = Dio();
        RequestOptions? capturedOption;

        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              capturedOption = options;
              return handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: '{}',
                ),
              );
            },
          ),
        );

        final transport = SyncTransport.dio(
          baseUrl: 'https://api.test.com',
          dio: dio,
        );

        await transport.pushCustom(
          url: 'https://api.test.com/orders',
          method: 'POST',
          mutationId: 'internal-mut-id',
          createdAtMs: 1700000000,
          payload: {'product': 'Chair'},
          headers: {
            'Idempotency-Key': 'developer-custom-key-777',
            'X-Tenant-ID': 'tenant-acme',
          },
        );

        expect(capturedOption!.headers['Idempotency-Key'],
            equals('developer-custom-key-777'));
        expect(capturedOption!.headers['X-Tenant-ID'], equals('tenant-acme'));

        transport.dispose();
      });
    });

    group('5. Request Dispatch & Error Mapping via Dio', () {
      test('dispatches clean domain body with all internal flags stripped',
          () async {
        final dio = Dio();
        String? capturedBodyStr;

        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              capturedBodyStr = options.data as String?;
              return handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 201,
                  data: '{"id":"srv-1"}',
                ),
              );
            },
          ),
        );

        final transport = SyncTransport.dio(
          baseUrl: 'https://api.test.com',
          dio: dio,
        );

        await transport.pushCustom(
          url: 'https://api.test.com/items',
          method: 'POST',
          mutationId: 'mut-clean-1',
          createdAtMs: 1700000000,
          payload: {
            'title': 'Sanitized Item',
            'price': 19.99,
            '_sync_status': 'in_flight',
            '_offline_meta': {'device': 'android'},
            'expires_at': 1700000100,
            'updated_at': 1700000050,
            '_base_snapshot_json': '{"title":"old"}',
          },
        );

        final decoded = jsonDecode(capturedBodyStr!) as Map<String, dynamic>;
        expect(decoded['title'], equals('Sanitized Item'));
        expect(decoded['price'], equals(19.99));
        expect(decoded.containsKey('_sync_status'), isFalse);
        expect(decoded.containsKey('_offline_meta'), isFalse);
        expect(decoded.containsKey('expires_at'), isFalse);
        expect(decoded.containsKey('updated_at'), isFalse);
        expect(decoded.containsKey('_base_snapshot_json'), isFalse);

        transport.dispose();
      });

      test(
          'maps Dio HTTP 400 and 500 error responses cleanly to TransportResponse',
          () async {
        final dio = Dio();
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              return handler.reject(
                DioException(
                  requestOptions: options,
                  response: Response(
                    requestOptions: options,
                    statusCode: 422,
                    data: '{"error":"Unprocessable Entity","field":"price"}',
                  ),
                  type: DioExceptionType.badResponse,
                ),
              );
            },
          ),
        );

        final transport = SyncTransport.dio(
          baseUrl: 'https://api.test.com',
          dio: dio,
        );

        final resp = await transport.pushCustom(
          url: 'https://api.test.com/items',
          method: 'POST',
          mutationId: 'mut-err-1',
          createdAtMs: 1700000000,
          payload: {'title': 'Bad Item'},
        );

        expect(resp.isSuccess, isFalse);
        expect(resp.statusCode, equals(422));
        expect(resp.body, contains('Unprocessable Entity'));

        transport.dispose();
      });

      test('maps Dio connection timeout to isNetworkError', () async {
        final dio = Dio();
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              return handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.connectionTimeout,
                  message: 'Connection timed out',
                ),
              );
            },
          ),
        );

        final transport = SyncTransport.dio(
          baseUrl: 'https://api.test.com',
          dio: dio,
        );

        final resp = await transport.pushCustom(
          url: 'https://api.test.com/items',
          method: 'POST',
          mutationId: 'mut-timeout-1',
          createdAtMs: 1700000000,
          payload: {'title': 'Timeout Item'},
        );

        expect(resp.isSuccess, isFalse);
        expect(resp.isNetworkError, isTrue);
        expect(resp.statusCode, equals(0));

        transport.dispose();
      });
    });
  });
}
