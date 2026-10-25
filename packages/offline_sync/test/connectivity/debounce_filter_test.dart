import 'dart:async';
import 'package:test/test.dart';
import 'package:offline_sync/src/connectivity/domain/policies/debounce_policy.dart';
import 'package:offline_sync/src/connectivity/services/debounced_state_machine.dart';

void main() {
  group('Layer 3 Connectivity: Debounced State Machine', () {
    test('Immediate 0ms disconnection transition without delay', () {
      final machine = DebouncedStateMachine(
        policy: const DebouncePolicy(
          stabilizationDuration: Duration(milliseconds: 100),
          disconnectDuration: Duration.zero,
        ),
      );

      expect(machine.isOnline, isTrue);

      bool? emittedState;
      machine.handleReachabilityUpdate(
        isPhysicallyOnline: false,
        onStateChanged: (online) => emittedState = online,
      );

      expect(machine.isOnline, isFalse);
      expect(emittedState, isFalse);
    });

    test('3s Reconnect stabilization suppresses rapid flapping before window elapses', () async {
      final machine = DebouncedStateMachine(
        policy: const DebouncePolicy(
          stabilizationDuration: Duration(milliseconds: 60),
          disconnectDuration: Duration.zero,
        ),
      );

      // Transition to offline first
      machine.handleReachabilityUpdate(
        isPhysicallyOnline: false,
        onStateChanged: (_) {},
      );
      expect(machine.isOnline, isFalse);

      final transitions = <bool>[];

      // Flap 1: signal briefly returns
      machine.handleReachabilityUpdate(
        isPhysicallyOnline: true,
        onStateChanged: (online) => transitions.add(online),
      );
      // Still false because 60ms stabilization window has not elapsed
      expect(machine.isOnline, isFalse);

      // Flap 2: signal drops 20ms later (cancelling pending debounce timer)
      await Future<void>.delayed(const Duration(milliseconds: 20));
      machine.handleReachabilityUpdate(
        isPhysicallyOnline: false,
        onStateChanged: (online) => transitions.add(online),
      );
      expect(machine.isOnline, isFalse);

      // Wait beyond the original 60ms window
      await Future<void>.delayed(const Duration(milliseconds: 60));
      // No spurious online event should have been emitted
      expect(machine.isOnline, isFalse);
      expect(transitions, isEmpty);
    });

    test('Stable reconnection transitions to online once stabilization window passes', () async {
      final machine = DebouncedStateMachine(
        policy: const DebouncePolicy(
          stabilizationDuration: Duration(milliseconds: 40),
          disconnectDuration: Duration.zero,
        ),
      );

      machine.handleReachabilityUpdate(
        isPhysicallyOnline: false,
        onStateChanged: (_) {},
      );
      expect(machine.isOnline, isFalse);

      final completer = Completer<bool>();
      machine.handleReachabilityUpdate(
        isPhysicallyOnline: true,
        onStateChanged: (online) => completer.complete(online),
      );

      expect(machine.isOnline, isFalse);
      final becameOnline = await completer.future;
      expect(becameOnline, isTrue);
      expect(machine.isOnline, isTrue);
    });

    test('bypassDebounce immediately transitions online without waiting for timer', () {
      final machine = DebouncedStateMachine(
        policy: const DebouncePolicy(
          stabilizationDuration: Duration(seconds: 10),
          disconnectDuration: Duration.zero,
        ),
      );

      machine.handleReachabilityUpdate(
        isPhysicallyOnline: false,
        onStateChanged: (_) {},
      );
      expect(machine.isOnline, isFalse);

      bool? emittedState;
      machine.handleReachabilityUpdate(
        isPhysicallyOnline: true,
        bypassDebounce: true,
        onStateChanged: (online) => emittedState = online,
      );

      expect(machine.isOnline, isTrue);
      expect(emittedState, isTrue);
    });
  });
}
