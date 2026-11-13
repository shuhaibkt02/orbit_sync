import 'dart:async';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';

void main() {
  group('Layer 5 Facade: Challenge 3 Leading-Immediate Debounce Stream Transformer', () {
    test('Leading-immediate debounce emits initial event with 0ms latency', () async {
      final controller = StreamController<int>();
      final emitted = <int>[];

      final debounced = controller.stream.leadingImmediateDebounce(const Duration(milliseconds: 100));
      final sub = debounced.listen(emitted.add);

      // First event emitted
      controller.add(42);
      await Future<void>.delayed(Duration.zero);

      // Assert emitted immediately without waiting 100ms
      expect(emitted, equals([42]));

      await sub.cancel();
      await controller.close();
    });

    test('Rapid consecutive events are coalesced to the trailing value', () async {
      final controller = StreamController<int>();
      final emitted = <int>[];

      final debounced = controller.stream.leadingImmediateDebounce(const Duration(milliseconds: 100));
      final sub = debounced.listen(emitted.add);

      // Event 1 (leading-immediate)
      controller.add(1);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Burst of rapid background writes within the 100ms window
      controller.add(2);
      controller.add(3);
      controller.add(4);

      // Assert only event 1 has been emitted so far
      expect(emitted, equals([1]));

      // Wait for debounce window to elapse
      await Future<void>.delayed(const Duration(milliseconds: 120));

      // Assert trailing event (4) was emitted; intermediate events 2 and 3 coalesced
      expect(emitted, equals([1, 4]));

      await sub.cancel();
      await controller.close();
    });
  });
}
