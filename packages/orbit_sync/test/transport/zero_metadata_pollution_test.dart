import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';

void main() {
  group('Layer 4 Transport: Zero Metadata Pollution & Clean Body Rule', () {
    test('pushCustom dispatches pure domain payload with zero _offline_meta in body', () async {
      String? capturedBody;
      Map<String, String>? capturedHeaders;

      final mockClient = MockClient((request) async {
        capturedBody = request.body;
        capturedHeaders = request.headers;
        return http.Response('{"status": "created", "id": "srv-99"}', 201);
      });

      final transport = SyncTransport.http(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
      );

      final domainPayload = {
        'title': 'Clean Architecture Task',
        'priority': 'high',
        'tags': ['sync', 'offline'],
        'details': {'amount': 150.50},
      };

      final response = await transport.pushCustom(
        url: 'https://api.example.com/v1/tasks',
        method: 'POST',
        mutationId: 'mut-12345',
        createdAtMs: DateTime.utc(2026, 10, 25, 12, 0, 0).millisecondsSinceEpoch,
        payload: domainPayload,
        entityId: 'temp-id-001',
        headers: {'X-Custom-Tenant': 'tenant-42'},
      );

      expect(response.isSuccess, isTrue);
      expect(response.statusCode, equals(201));

      // 1. Verify JSON body is 100% clean domain data: zero injected temporary ID
      final decodedBody = jsonDecode(capturedBody!) as Map<String, dynamic>;
      expect(decodedBody.containsKey('id'), isFalse);
      expect(decodedBody['title'], equals('Clean Architecture Task'));
      expect(decodedBody['priority'], equals('high'));
      expect(decodedBody['tags'], equals(['sync', 'offline']));
      expect(decodedBody['details'], equals({'amount': 150.50}));

      // Internal metadata must NEVER leak into body
      expect(decodedBody.containsKey('_offline_meta'), isFalse);
      expect(decodedBody.containsKey('mutation_id'), isFalse);
      expect(decodedBody.containsKey('_sync_status'), isFalse);

      // 2. Zero Metadata Pollution: zero injected metadata in headers (vanilla REST)
      expect(capturedHeaders!['content-type'], equals('application/json'));
      expect(capturedHeaders!['x-custom-tenant'] ?? capturedHeaders!['X-Custom-Tenant'], equals('tenant-42'));
      expect(capturedHeaders!.containsKey('idempotency-key'), isFalse);
      expect(capturedHeaders!.containsKey('x-client-mutation-id'), isFalse);
      expect(capturedHeaders!.containsKey('x-offline-sync'), isFalse);
      expect(capturedHeaders!.containsKey('x-offline-created-at'), isFalse);

      // Verify that when the domain payload explicitly provides an id, it is preserved
      await transport.pushCustom(
        url: 'https://api.example.com/v1/tasks',
        method: 'POST',
        mutationId: 'mut-12346',
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        payload: {'id': 'explicit-id-123', 'title': 'Preserved ID'},
        entityId: 'explicit-id-123',
      );
      final explicitDecoded = jsonDecode(capturedBody!) as Map<String, dynamic>;
      expect(explicitDecoded['id'], equals('explicit-id-123'));
    });

    test('DELETE operations send zero body payload and format route ID properly', () async {
      String? capturedMethod;
      String? capturedUrl;
      String? capturedBody;
      Map<String, String>? capturedHeaders;

      final mockClient = MockClient((request) async {
        capturedMethod = request.method;
        capturedUrl = request.url.toString();
        capturedBody = request.body;
        capturedHeaders = request.headers;
        return http.Response('', 204);
      });

      final transport = SyncTransport.http(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
      );

      final response = await transport.pushCustom(
        url: 'https://api.example.com/v1/tasks',
        method: 'DELETE',
        mutationId: 'mut-del-77',
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        entityId: 'task-404',
        headers: {'X-Audit-Reason': 'User request'},
      );

      expect(response.isSuccess, isTrue);
      expect(capturedMethod, equals('DELETE'));
      expect(capturedUrl, equals('https://api.example.com/v1/tasks/task-404'));
      expect(capturedBody, isEmpty);
      expect(capturedHeaders!['x-audit-reason'] ?? capturedHeaders!['X-Audit-Reason'], equals('User request'));
      expect(capturedHeaders!.containsKey('idempotency-key'), isFalse);
      expect(capturedHeaders!.containsKey('x-client-mutation-id'), isFalse);
      expect(capturedHeaders!.containsKey('x-offline-sync'), isFalse);
      expect(capturedHeaders!.containsKey('x-offline-created-at'), isFalse);
    });
  });
}
