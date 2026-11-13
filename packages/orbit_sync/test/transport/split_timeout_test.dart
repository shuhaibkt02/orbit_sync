import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';

class _StallingClient extends http.BaseClient {
  final Duration stallConnect;
  final Duration stallBody;

  _StallingClient({
    this.stallConnect = Duration.zero,
    this.stallBody = Duration.zero,
  });

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (stallConnect > Duration.zero) {
      await Future<void>.delayed(stallConnect);
    }

    Stream<List<int>> byteStream;
    if (stallBody > Duration.zero) {
      final controller = StreamController<List<int>>();
      // Simulate zombie stream that freezes mid-transfer
      Future<void>.delayed(stallBody, () {
        if (!controller.isClosed) controller.close();
      });
      byteStream = controller.stream;
    } else {
      byteStream = Stream.value([123, 125]); // "{}"
    }

    return http.StreamedResponse(byteStream, 200);
  }
}

void main() {
  group('Layer 4 Transport: Split Timeout & Zombie Socket Defense', () {
    test('Connect timeout triggers when connection handshake stalls', () async {
      final stallingClient = _StallingClient(stallConnect: const Duration(milliseconds: 150));
      final adapter = DefaultHttpAdapter(client: stallingClient);

      final req = TransportRequest(
        uri: Uri.parse('https://example.com/api/test'),
        method: 'GET',
        connectTimeout: const Duration(milliseconds: 50),
        readTimeout: const Duration(seconds: 5),
      );

      final response = await adapter.send(req);
      expect(response.isSuccess, isFalse);
      expect(response.isNetworkError, isTrue);
      expect(response.statusCode, equals(0));
      expect(response.error, isA<TimeoutException>());
      expect(response.error.toString(), contains('Connect timeout'));

      adapter.dispose();
      stallingClient.close();
    });

    test('Read/transfer timeout triggers when response stream hangs mid-flight', () async {
      final stallingClient = _StallingClient(stallBody: const Duration(milliseconds: 200));
      final adapter = DefaultHttpAdapter(client: stallingClient);

      final req = TransportRequest(
        uri: Uri.parse('https://example.com/api/test'),
        method: 'GET',
        connectTimeout: const Duration(seconds: 2),
        readTimeout: const Duration(milliseconds: 50),
      );

      final response = await adapter.send(req);
      expect(response.isSuccess, isFalse);
      expect(response.isNetworkError, isTrue);
      expect(response.statusCode, equals(0));
      expect(response.error, isA<TimeoutException>());
      expect(response.error.toString(), contains('Read timeout'));

      adapter.dispose();
      stallingClient.close();
    });

    test('Fast response within timeouts succeeds normally', () async {
      final fastClient = _StallingClient();
      final adapter = DefaultHttpAdapter(client: fastClient);

      final req = TransportRequest(
        uri: Uri.parse('https://example.com/api/test'),
        method: 'GET',
        connectTimeout: const Duration(milliseconds: 100),
        readTimeout: const Duration(milliseconds: 100),
      );

      final response = await adapter.send(req);
      expect(response.isSuccess, isTrue);
      expect(response.statusCode, equals(200));
      expect(response.body, equals('{}'));

      adapter.dispose();
      fastClient.close();
    });
  });
}
