import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';

void main() {
  group('Layer 4 Transport: HTTP 401 Auth Expiration & Forwarding', () {
    test('401 response from server returns cleanly without internal throws or retries', () async {
      final mockClient = MockClient((request) async {
        return http.Response('{"error": "jwt_expired"}', 401, headers: {'www-authenticate': 'Bearer'});
      });

      final transport = SyncTransport.http(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
      );

      final resp = await transport.pushCustom(
        url: 'https://api.example.com/v1/orders',
        method: 'POST',
        mutationId: 'm-1',
        createdAtMs: 1000,
        payload: {'item': 'book'},
      );

      expect(resp.isSuccess, isFalse);
      expect(resp.isNetworkError, isFalse);
      expect(resp.statusCode, equals(401));
      expect(resp.body, contains('jwt_expired'));
      expect(resp.headers['www-authenticate'], equals('Bearer'));
    });

    test('Transport dynamically retrieves fresh auth token on subsequent requests', () async {
      String currentToken = 'token-alpha';
      String? sentAuthHeader;

      final mockClient = MockClient((request) async {
        sentAuthHeader = request.headers['authorization'];
        return http.Response('{"status": "ok"}', 200);
      });

      final transport = SyncTransport.http(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
        getAuthToken: () async => currentToken,
      );

      await transport.pushBatch(mutations: [], idempotencyKey: 'k-1');
      expect(sentAuthHeader, equals('Bearer token-alpha'));

      // Simulate token refresh
      currentToken = 'token-beta';
      await transport.pushBatch(mutations: [], idempotencyKey: 'k-2');
      expect(sentAuthHeader, equals('Bearer token-beta'));
    });
  });
}
