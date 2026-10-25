import 'package:test/test.dart';
import 'package:offline_sync/offline_sync.dart';

void main() {
  group('Layer 4 Transport: Extension Factory Stubs & Polymorphism', () {
    test('SyncTransport.webSocket throws UnsupportedError describing v1.1 roadmap', () {
      expect(
        () => SyncTransport.webSocket(url: 'wss://api.example.com/sync'),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            contains('WebSocket transport is planned for Orbit v1.1'),
          ),
        ),
      );
    });

    test('SyncTransport.grpc throws UnsupportedError describing v1.2 roadmap', () {
      expect(
        () => SyncTransport.grpc(host: 'api.example.com', port: 50051),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            contains('gRPC transport is planned for Orbit v1.2'),
          ),
        ),
      );
    });

    test('SyncTransport.graphql throws UnsupportedError describing v1.3 roadmap', () {
      expect(
        () => SyncTransport.graphql(endpoint: 'https://api.example.com/graphql'),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            contains('GraphQL transport is planned for Orbit v1.3'),
          ),
        ),
      );
    });
  });
}
