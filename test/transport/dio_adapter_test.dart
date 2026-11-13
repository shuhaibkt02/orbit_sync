import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';

void main() {
  group('Layer 4 Transport: Enterprise Dio Adapter', () {
    test('SyncTransport.dio sends requests through Dio interceptors cleanly', () async {
      final dio = Dio();
      String? interceptedAuthHeader;
      String? capturedBody;

      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            interceptedAuthHeader = options.headers['authorization'];
            capturedBody = options.data?.toString();
            // Mock server response
            return handler.resolve(
              Response(
                requestOptions: options,
                data: '{"status": "success", "id": "dio-101"}',
                statusCode: 201,
              ),
            );
          },
        ),
      );

      final transport = SyncTransport.dio(
        baseUrl: 'https://enterprise.example.com',
        dio: dio,
        getAuthToken: () async => 'enterprise-jwt-token',
      );

      final resp = await transport.pushCustom(
        url: 'https://enterprise.example.com/v1/assets',
        method: 'POST',
        mutationId: 'mut-dio-1',
        createdAtMs: DateTime.utc(2026, 10, 25, 12, 0, 0).millisecondsSinceEpoch,
        payload: {'asset_tag': 'ASSET-999', 'model': 'Dell XPS'},
        entityId: 'dio-101',
      );

      expect(resp.isSuccess, isTrue);
      expect(resp.statusCode, equals(201));
      expect(interceptedAuthHeader, equals('Bearer enterprise-jwt-token'));

      // Assert zero metadata pollution in body
      final bodyMap = jsonDecode(capturedBody!) as Map<String, dynamic>;
      expect(bodyMap['asset_tag'], equals('ASSET-999'));
      expect(bodyMap.containsKey('_offline_meta'), isFalse);

      transport.dispose();
    });

    test('DioException 401 mapped cleanly to TransportResponse', () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            return handler.reject(
              DioException(
                requestOptions: options,
                response: Response(
                  requestOptions: options,
                  statusCode: 401,
                  data: '{"error": "Unauthorized"}',
                ),
                type: DioExceptionType.badResponse,
              ),
            );
          },
        ),
      );

      final transport = SyncTransport.dio(
        baseUrl: 'https://enterprise.example.com',
        dio: dio,
      );

      final resp = await transport.pushBatch(mutations: [], idempotencyKey: 'k-1');
      expect(resp.isSuccess, isFalse);
      expect(resp.statusCode, equals(401));
      expect(resp.body, contains('Unauthorized'));

      transport.dispose();
    });

    test('Dio connection timeout mapped cleanly to isNetworkError', () async {
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
        baseUrl: 'https://enterprise.example.com',
        dio: dio,
      );

      final resp = await transport.pull(sinceCursor: 0, limit: 10);
      expect(resp.isSuccess, isFalse);
      expect(resp.isNetworkError, isTrue);
      expect(resp.statusCode, equals(0));

      transport.dispose();
    });
  });
}
