import 'dart:async';
import 'package:test/test.dart';
import 'package:orbit_sync/src/connectivity/connectivity_monitor.dart';

class _FakeProbe implements INetworkProbe {
  int callCount = 0;
  bool nextOnline = false;

  @override
  Future<ProbeResult> probe(Uri target, {Duration? timeout}) async {
    callCount++;
    return ProbeResult(
      isOnline: nextOnline,
      isCaptivePortal: false,
      statusCode: nextOnline ? 204 : 0,
    );
  }

  @override
  void dispose() {}
}

void main() {
  group('Layer 3 Connectivity: Heartbeat & Lifecycle', () {
    test('ConnectivityMonitor polls periodically in dead zone and stops when online', () async {
      final probe = _FakeProbe()..nextOnline = false;
      final monitor = ConnectivityMonitor(
        probe: probe,
        heartbeatInterval: const Duration(milliseconds: 30),
      );

      // Force offline to start heartbeat
      await monitor.checkReachability();
      expect(monitor.isOnline, isFalse);
      final initialCount = probe.callCount;

      await Future<void>.delayed(const Duration(milliseconds: 95));
      expect(probe.callCount, greaterThanOrEqualTo(initialCount + 2));

      // Reconnecting stops heartbeat
      probe.nextOnline = true;
      await monitor.checkReachability(bypassDebounce: true);
      expect(monitor.isOnline, isTrue);

      final countWhenOnline = probe.callCount;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(probe.callCount, equals(countWhenOnline));

      monitor.dispose();
    });

    test('Entering dead zone triggers onScheduleNativeAlarm callback for OS alarm integration', () async {
      final probe = _FakeProbe()..nextOnline = false;
      var alarmScheduled = false;

      final monitor = ConnectivityMonitor(
        probe: probe,
        onScheduleNativeAlarm: () async {
          alarmScheduled = true;
        },
      );

      expect(alarmScheduled, isFalse);
      await monitor.checkReachability();
      expect(monitor.isOnline, isFalse);
      expect(alarmScheduled, isTrue);

      monitor.dispose();
    });

    test('notifyAppResumed triggers immediate reachability check bypassing debounce', () async {
      final probe = _FakeProbe()..nextOnline = true;
      final monitor = ConnectivityMonitor(
        probe: probe,
        debouncePolicy: const DebouncePolicy(
          stabilizationDuration: Duration(seconds: 10),
          disconnectDuration: Duration.zero,
        ),
      );

      // Force offline
      probe.nextOnline = false;
      await monitor.checkReachability();
      expect(monitor.isOnline, isFalse);

      // System resumes and connectivity is back
      probe.nextOnline = true;
      await monitor.notifyAppResumed();

      // Immediate online without waiting 10 seconds
      expect(monitor.isOnline, isTrue);

      monitor.dispose();
    });

    test('ConnectivityMonitor.dispose cleanly shuts down all streams and timers', () async {
      final monitor = ConnectivityMonitor();
      expect(monitor.onConnectivityChanged.isBroadcast, isTrue);
      expect(monitor.onStateChanged.isBroadcast, isTrue);

      monitor.dispose();

      // Subsequent event adds or listeners on closed controller should be closed
      expect(monitor.onConnectivityChanged, emitsDone);
      expect(monitor.onStateChanged, emitsDone);
    });
  });
}
