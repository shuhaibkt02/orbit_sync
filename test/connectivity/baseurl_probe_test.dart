import 'dart:async';
import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orbit_sync/src/connectivity/connectivity_monitor.dart';
import 'package:orbit_sync/src/connectivity/infrastructure/default_network_type_provider.dart';
import 'package:orbit_sync/src/connectivity/infrastructure/http_network_probe.dart';

class _RecordingProbe implements INetworkProbe {
  final List<Uri> probedUris = [];
  bool returnOnline = true;
  bool returnCaptivePortal = false;
  int statusCode = 200;

  @override
  Future<ProbeResult> probe(Uri targetUri, {Duration? timeout}) async {
    probedUris.add(targetUri);
    if (returnCaptivePortal) {
      return ProbeResult.captivePortal(
        statusCode: statusCode,
        redirectUrl: Uri.parse('https://portal.hotel.com/login'),
      );
    }
    return returnOnline
        ? ProbeResult.online(statusCode: statusCode)
        : ProbeResult.unreachable(errorMessage: 'Offline');
  }

  @override
  void dispose() {}
}

void main() {
  group('Ticket 15: BaseUrl Reachability Sensing & Custom Probe Targeting', () {
    test('Probe targets developer configured baseUrl', () async {
      final recordingProbe = _RecordingProbe();
      final monitor = ConnectivityMonitor(
        probe: recordingProbe,
        baseUrl: 'https://api.mycompany.com',
        debouncePolicy: DebouncePolicy.immediate,
      );

      await monitor.checkReachability();
      expect(recordingProbe.probedUris,
          equals([Uri.parse('https://api.mycompany.com')]));
      expect(monitor.isOnline, isTrue);
      monitor.dispose();
    });

    test(
        'Probe targets custom probeUrl when both probeUrl and baseUrl are configured',
        () async {
      final recordingProbe = _RecordingProbe();
      final monitor = ConnectivityMonitor(
        probe: recordingProbe,
        baseUrl: 'https://api.mycompany.com',
        probeUrl: 'https://api.mycompany.com/health',
        debouncePolicy: DebouncePolicy.immediate,
      );

      await monitor.checkReachability();
      expect(recordingProbe.probedUris,
          equals([Uri.parse('https://api.mycompany.com/health')]));
      monitor.dispose();
    });

    test(
        'Probe falls back to clean default when neither baseUrl nor probeUrl is provided',
        () async {
      final recordingProbe = _RecordingProbe();
      final monitor = ConnectivityMonitor(
        probe: recordingProbe,
        debouncePolicy: DebouncePolicy.immediate,
      );

      await monitor.checkReachability();
      expect(recordingProbe.probedUris,
          equals([Uri.parse(ConnectivityMonitor.fallbackProbeUrl)]));
      expect(ConnectivityMonitor.fallbackProbeUrl.contains('gstatic'), isFalse);
      monitor.dispose();
    });

    test(
        'checkReachability(targetUrl) dynamically overrides configured probe URL',
        () async {
      final recordingProbe = _RecordingProbe();
      final monitor = ConnectivityMonitor(
        probe: recordingProbe,
        baseUrl: 'https://api.mycompany.com',
        debouncePolicy: DebouncePolicy.immediate,
      );

      await monitor.checkReachability(
          targetUrl: 'https://override.example.com/ping');
      expect(recordingProbe.probedUris,
          equals([Uri.parse('https://override.example.com/ping')]));
      monitor.dispose();
    });
  });

  group('Ticket 15: Asymmetric Network Debouncing & Flapping Protection', () {
    test(
        'Standard DebouncePolicy defaults to 1.5s reconnect stabilization and 0ms disconnect',
        () {
      expect(DebouncePolicy.standard.stabilizationDuration,
          equals(const Duration(milliseconds: 1500)));
      expect(DebouncePolicy.standard.disconnectDuration, equals(Duration.zero));
    });

    test('Signals offline immediately (0ms) when network disconnects',
        () async {
      final recordingProbe = _RecordingProbe()..returnOnline = true;
      final monitor = ConnectivityMonitor(
        probe: recordingProbe,
        debouncePolicy: DebouncePolicy.standard,
      );

      expect(monitor.isOnline, isTrue);

      final stopwatch = Stopwatch()..start();
      recordingProbe.returnOnline = false;
      await monitor.checkReachability();
      stopwatch.stop();

      expect(monitor.isOnline, isFalse);
      expect(stopwatch.elapsedMilliseconds,
          lessThan(100)); // 0ms delay without waiting 1.5s
      monitor.dispose();
    });

    test(
        'Asymmetric 1.5s debounce: suppresses online status until 1.5s window elapses',
        () async {
      final recordingProbe = _RecordingProbe()..returnOnline = false;
      final monitor = ConnectivityMonitor(
        probe: recordingProbe,
        debouncePolicy: DebouncePolicy.standard,
      );

      // Go offline
      await monitor.checkReachability();
      expect(monitor.isOnline, isFalse);

      // Signal returns
      recordingProbe.returnOnline = true;
      await monitor.checkReachability();

      // Before 1.5s window elapses, device is still considered offline
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(monitor.isOnline, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(monitor.isOnline, isFalse);

      // After full 1.5s window passes, device becomes online
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(monitor.isOnline, isTrue);

      monitor.dispose();
    });

    test(
        'Flapping protection: reconnect canceled if network cuts within 1.5s window',
        () async {
      final recordingProbe = _RecordingProbe()..returnOnline = false;
      final monitor = ConnectivityMonitor(
        probe: recordingProbe,
        debouncePolicy: DebouncePolicy.standard,
      );

      await monitor.checkReachability();
      expect(monitor.isOnline, isFalse);

      final events = <bool>[];
      final sub = monitor.onConnectivityChanged.listen(events.add);

      // Flap 1: signal briefly returns
      recordingProbe.returnOnline = true;
      await monitor.checkReachability();
      expect(monitor.isOnline, isFalse);

      // Flap 2: connection cuts again 400ms later (canceling debounce)
      await Future<void>.delayed(const Duration(milliseconds: 400));
      recordingProbe.returnOnline = false;
      await monitor.checkReachability();
      expect(monitor.isOnline, isFalse);

      // Wait beyond the original 1.5s window
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      expect(monitor.isOnline, isFalse);
      expect(events, isEmpty);

      await sub.cancel();
      monitor.dispose();
    });

    test('bypassDebounce immediately transitions online without waiting 1.5s',
        () async {
      final recordingProbe = _RecordingProbe()..returnOnline = false;
      final monitor = ConnectivityMonitor(
        probe: recordingProbe,
        debouncePolicy: DebouncePolicy.standard,
      );

      await monitor.checkReachability();
      expect(monitor.isOnline, isFalse);

      recordingProbe.returnOnline = true;
      await monitor.checkReachability(bypassDebounce: true);
      expect(monitor.isOnline, isTrue);

      monitor.dispose();
    });
  });

  group('Ticket 15: Captive Portal Detection', () {
    test(
        'Probe returning Content-Type: text/html flags isCaptivePortal: true and isOnline: false',
        () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          '<html><head><title>Hotel Login</title></head><body>Please authenticate</body></html>',
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
          request: request,
        );
      });

      final probe = HttpNetworkProbe(client: mockClient);
      final monitor = ConnectivityMonitor(
        probe: probe,
        baseUrl: 'https://api.mycompany.com',
        debouncePolicy: DebouncePolicy.immediate,
      );

      await monitor.checkReachability();
      expect(monitor.isOnline, isFalse);
      expect(monitor.state.isOnline, isFalse);
      expect(monitor.state.isCaptivePortal, isTrue);

      monitor.dispose();
    });

    test(
        'Probe returning HTML body without text/html header flags isCaptivePortal: true and isOnline: false',
        () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          '<!DOCTYPE html><html><body>Airport Free Wi-Fi Login</body></html>',
          200,
          headers: {'content-type': 'text/plain'},
          request: request,
        );
      });

      final probe = HttpNetworkProbe(client: mockClient);
      final result =
          await probe.probe(Uri.parse('https://api.mycompany.com/health'));

      expect(result.isOnline, isFalse);
      expect(result.isCaptivePortal, isTrue);
      expect(result.errorMessage, contains('HTML'));
      probe.dispose();
    });

    test(
        'Unexpected 302 redirect to external captive portal domain flags isCaptivePortal: true',
        () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          '',
          302,
          headers: {'location': 'https://wifi-portal.hotel.com/login'},
          request: request,
        );
      });

      final probe = HttpNetworkProbe(client: mockClient);
      final monitor = ConnectivityMonitor(
        probe: probe,
        baseUrl: 'https://api.mycompany.com',
        debouncePolicy: DebouncePolicy.immediate,
      );

      await monitor.checkReachability();
      expect(monitor.isOnline, isFalse);
      expect(monitor.state.isCaptivePortal, isTrue);

      monitor.dispose();
    });

    test(
        'Unexpected 302 redirect to relative portal path flags isCaptivePortal: true',
        () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          '',
          302,
          headers: {'location': '/guest/s/default/login'},
          request: request,
        );
      });

      final probe = HttpNetworkProbe(client: mockClient);
      final result =
          await probe.probe(Uri.parse('https://api.mycompany.com/health'));

      expect(result.isOnline, isFalse);
      expect(result.isCaptivePortal, isTrue);
      probe.dispose();
    });

    test(
        'Clean 200 OK JSON response flags isOnline: true and isCaptivePortal: false',
        () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          '{"status": "healthy"}',
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      });

      final probe = HttpNetworkProbe(client: mockClient);
      final monitor = ConnectivityMonitor(
        probe: probe,
        baseUrl: 'https://api.mycompany.com',
        debouncePolicy: DebouncePolicy.immediate,
      );

      await monitor.checkReachability();
      expect(monitor.isOnline, isTrue);
      expect(monitor.state.isOnline, isTrue);
      expect(monitor.state.isCaptivePortal, isFalse);

      monitor.dispose();
    });

    test(
        'Gateway 401/403/404 JSON response proves gateway reachability without captive portal',
        () async {
      for (final code in [401, 403, 404]) {
        final mockClient = MockClient((request) async {
          return http.Response(
            '{"error": "Unauthorized"}',
            code,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        });

        final probe = HttpNetworkProbe(client: mockClient);
        final result =
            await probe.probe(Uri.parse('https://api.mycompany.com/health'));

        expect(result.isOnline, isTrue,
            reason: 'Status $code from gateway proves DNS & TLS reachability');
        expect(result.isCaptivePortal, isFalse);
        probe.dispose();
      }
    });
  });

  group('Ticket 15: Metered vs Unmetered Connection Detection', () {
    test('Detects cellular and bluetooth as metered connections', () {
      expect(NetworkConnectionType.cellular.isMetered, isTrue);
      expect(NetworkConnectionType.bluetooth.isMetered, isTrue);
    });

    test('Detects wifi, ethernet, and vpn as unmetered connections', () {
      expect(NetworkConnectionType.wifi.isMetered, isFalse);
      expect(NetworkConnectionType.ethernet.isMetered, isFalse);
      expect(NetworkConnectionType.vpn.isMetered, isFalse);
    });

    test(
        'Connection type transitions dynamically update ConnectivityMonitor and emit state',
        () async {
      final typeProvider = DefaultNetworkTypeProvider();
      final monitor = ConnectivityMonitor(
        probe: _RecordingProbe(),
        typeProvider: typeProvider,
        debouncePolicy: DebouncePolicy.immediate,
      );

      final stateList = <ConnectivityState>[];
      final sub = monitor.onStateChanged.listen(stateList.add);

      // Transition to cellular
      typeProvider.setConnectionType(NetworkConnectionType.cellular);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(monitor.isMetered, isTrue);
      expect(monitor.state.isMetered, isTrue);
      expect(monitor.state.type, equals(NetworkConnectionType.cellular));

      // Transition to wifi
      typeProvider.setConnectionType(NetworkConnectionType.wifi);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(monitor.isMetered, isFalse);
      expect(monitor.state.isMetered, isFalse);
      expect(monitor.state.type, equals(NetworkConnectionType.wifi));

      await sub.cancel();
      monitor.dispose();
    });
  });
}
