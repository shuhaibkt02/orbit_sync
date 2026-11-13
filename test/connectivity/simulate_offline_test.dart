import 'dart:async';
import 'package:test/test.dart';
import 'package:orbit_sync/src/connectivity/connectivity_monitor.dart';

class _SpyNetworkProbe implements INetworkProbe {
  int probeCallCount = 0;
  bool returnOnline = true;

  @override
  Future<ProbeResult> probe(Uri target, {Duration? timeout}) async {
    probeCallCount++;
    return ProbeResult(
      isOnline: returnOnline,
      isCaptivePortal: false,
      statusCode: returnOnline ? 204 : 0,
    );
  }

  @override
  void dispose() {}
}

void main() {
  group('Layer 3 Connectivity: Simulated Offline Mode', () {
    test(
        'simulateOffline = true instantly transitions offline without making network calls',
        () async {
      final spyProbe = _SpyNetworkProbe();
      final monitor = ConnectivityMonitor(
        probe: spyProbe,
        debouncePolicy: const DebouncePolicy(
          stabilizationDuration: Duration(milliseconds: 50),
          disconnectDuration: Duration.zero,
        ),
      );

      expect(monitor.isOnline, isTrue);

      final events = <bool>[];
      final sub = monitor.onConnectivityChanged.listen(events.add);

      // Turn on simulation
      monitor.simulateOffline = true;
      expect(monitor.isOnline, isFalse);
      expect(monitor.simulateOffline, isTrue);

      // Reachability check while simulated offline returns false and calls 0 network probes
      final check = await monitor.checkReachability();
      expect(check, isFalse);
      expect(spyProbe.probeCallCount, equals(0));

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(events, contains(false));

      // Turn off simulation automatically initiates reachability check
      monitor.simulateOffline = false;
      expect(monitor.simulateOffline, isFalse);
      expect(monitor.isOnline, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(spyProbe.probeCallCount, equals(1));

      // Subsequent reachability check probes again
      final onlineCheck = await monitor.checkReachability(bypassDebounce: true);
      expect(onlineCheck, isTrue);
      expect(spyProbe.probeCallCount, equals(2));

      await sub.cancel();
      monitor.dispose();
    });

    test(
        'state property and onStateChanged stream reflect rich state transitions',
        () async {
      final spyProbe = _SpyNetworkProbe();
      final monitor = ConnectivityMonitor(
        probe: spyProbe,
        debouncePolicy: const DebouncePolicy(
          stabilizationDuration: Duration(milliseconds: 20),
          disconnectDuration: Duration.zero,
        ),
      );

      final states = <ConnectivityState>[];
      final sub = monitor.onStateChanged.listen(states.add);

      monitor.simulateOffline = true;
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(monitor.state.isOnline, isFalse);
      expect(states.last.isOnline, isFalse);

      await sub.cancel();
      monitor.dispose();
    });
  });
}
