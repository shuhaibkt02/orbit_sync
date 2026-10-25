import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:offline_sync/src/connectivity/infrastructure/http_network_probe.dart';

void main() {
  group('Layer 3 Connectivity: Captive Portal & Probe Rules', () {
    test('302 redirect to external captive portal flags isCaptivePortal: true and isOnline: false', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          '',
          302,
          headers: {'location': 'https://wifi-portal.hotel.com/login'},
          request: request,
        );
      });

      final probe = HttpNetworkProbe(client: mockClient);
      final result = await probe.probe(
        Uri.parse('http://connectivitycheck.gstatic.com/generate_204'),
      );

      expect(result.isOnline, isFalse);
      expect(result.isCaptivePortal, isTrue);
      expect(result.statusCode, equals(302));
      expect(result.redirectUrl, equals(Uri.parse('https://wifi-portal.hotel.com/login')));
    });

    test('HTTP 204 No Content confirms true reachability without captive portal', () async {
      final mockClient = MockClient((request) async {
        return http.Response('', 204, request: request);
      });

      final probe = HttpNetworkProbe(client: mockClient);
      final result = await probe.probe(
        Uri.parse('http://connectivitycheck.gstatic.com/generate_204'),
      );

      expect(result.isOnline, isTrue);
      expect(result.isCaptivePortal, isFalse);
      expect(result.statusCode, equals(204));
    });

    test('Gateway 401/403/404 Reachability Rule: Direct API errors prove DNS & TLS reachability', () async {
      final probeUrl = Uri.parse('https://api.mycompany.com/v1/health');

      for (final code in [401, 403, 404]) {
        final mockClient = MockClient((request) async {
          return http.Response('{"error": "Denied"}', code, request: request);
        });

        final probe = HttpNetworkProbe(client: mockClient);
        final result = await probe.probe(probeUrl);

        expect(result.isOnline, isTrue, reason: 'Status code $code directly proves gateway reachability');
        expect(result.isCaptivePortal, isFalse);
        expect(result.statusCode, equals(code));
      }
    });

    test('Network timeout or socket failure returns isOnline: false', () async {
      final mockClient = MockClient((request) async {
        throw http.ClientException('Connection refused');
      });

      final probe = HttpNetworkProbe(client: mockClient);
      final result = await probe.probe(Uri.parse('https://api.example.com'));

      expect(result.isOnline, isFalse);
      expect(result.isCaptivePortal, isFalse);
      expect(result.errorMessage, isNotNull);
    });
  });
}
