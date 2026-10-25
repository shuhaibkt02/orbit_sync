import 'dart:async';
import 'package:test/test.dart';
import 'package:offline_sync/src/connectivity/connectivity_monitor.dart';
import 'package:offline_sync/src/connectivity/services/heartbeat_scheduler.dart';

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
  group('Layer 3 Connectivity: Heartbeat Scheduler & Lifecycle', () {
    test('HeartbeatScheduler fires periodically when active and halts when stopped', () async {
      int checkCount = 0;
      final scheduler = HeartbeatScheduler(
        interval: const Duration(milliseconds: 30),
        onCheck: () async {
          checkCount++;
          return false;
        },
      );

      expect(scheduler.isActive, isFalse);
      scheduler.start();
      expect(scheduler.isActive, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 95));
      expect(checkCount, greaterThanOrEqualTo(2));

      scheduler.stop();
      expect(scheduler.isActive, isFalse);
      final countAfterStop = checkCount;

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(checkCount, equals(countAfterStop));

      scheduler.dispose();
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
