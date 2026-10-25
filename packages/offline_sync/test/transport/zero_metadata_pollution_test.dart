import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:offline_sync/offline_sync.dart';

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
        serverUrl: 'https://api.example.com',
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
      );

      expect(response.isSuccess, isTrue);
      expect(response.statusCode, equals(201));

      // 1. Verify JSON body is 100% clean domain data
      final decodedBody = jsonDecode(capturedBody!) as Map<String, dynamic>;
      expect(decodedBody['id'], equals('temp-id-001'));
      expect(decodedBody['title'], equals('Clean Architecture Task'));
      expect(decodedBody['priority'], equals('high'));
      expect(decodedBody['tags'], equals(['sync', 'offline']));
      expect(decodedBody['details'], equals({'amount': 150.50}));

      // Internal metadata must NEVER leak into body
      expect(decodedBody.containsKey('_offline_meta'), isFalse);
      expect(decodedBody.containsKey('mutation_id'), isFalse);
      expect(decodedBody.containsKey('_sync_status'), isFalse);

      // 2. Verify all sync metadata is transported exclusively via HTTP headers
      expect(capturedHeaders!['idempotency-key'], equals('mut-12345'));
      expect(capturedHeaders!['x-client-mutation-id'], equals('mut-12345'));
      expect(capturedHeaders!['x-offline-sync'], equals('true'));
      expect(capturedHeaders!['x-offline-created-at'], equals('2026-10-25T12:00:00.000Z'));
      expect(capturedHeaders!['content-type'], equals('application/json'));
    });

    test('DELETE operations send zero body payload and format route ID properly', () async {
      String? capturedMethod;
      String? capturedUrl;
      String? capturedBody;

      final mockClient = MockClient((request) async {
        capturedMethod = request.method;
        capturedUrl = request.url.toString();
        capturedBody = request.body;
        return http.Response('', 204);
      });

      final transport = SyncTransport.http(
        serverUrl: 'https://api.example.com',
        httpClient: mockClient,
      );

      final response = await transport.pushCustom(
        url: 'https://api.example.com/v1/tasks',
        method: 'DELETE',
        mutationId: 'mut-del-77',
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        entityId: 'task-404',
      );

      expect(response.isSuccess, isTrue);
      expect(capturedMethod, equals('DELETE'));
      expect(capturedUrl, equals('https://api.example.com/v1/tasks/task-404'));
      expect(capturedBody, isEmpty);
    });
  });
}
