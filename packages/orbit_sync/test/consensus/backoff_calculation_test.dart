import 'dart:math';
import 'package:test/test.dart';
import 'package:orbit_sync/offline_sync.dart';

void main() {
  group('Layer 2 Consensus: BackoffPolicy Calculations', () {
    test('Test 1: Monotonic capped backoff schedule', () {
      final policy = BackoffPolicy(
        base: const Duration(seconds: 1),
        max: const Duration(seconds: 30),
        jitterFraction: 0,
      );

      expect(policy.delayFor(0), equals(Duration.zero));
      expect(policy.delayFor(1), equals(const Duration(seconds: 1)));
      expect(policy.delayFor(2), equals(const Duration(seconds: 2)));
      expect(policy.delayFor(3), equals(const Duration(seconds: 4)));
      expect(policy.delayFor(4), equals(const Duration(seconds: 8)));
      expect(policy.delayFor(5), equals(const Duration(seconds: 16)));
      expect(policy.delayFor(6), equals(const Duration(seconds: 30)));
      expect(policy.delayFor(10), equals(const Duration(seconds: 30)));
      expect(policy.delayFor(25), equals(const Duration(seconds: 30)));

      expect(policy.delayFor(0) < policy.delayFor(1), isTrue);
      expect(policy.delayFor(1) < policy.delayFor(2), isTrue);
      expect(policy.delayFor(2) < policy.delayFor(5), isTrue);
      expect(policy.delayFor(5) <= const Duration(seconds: 30), isTrue);
    });

    test('Test 2: Bounded jitter calculation', () {
      final policy = BackoffPolicy(
        base: const Duration(milliseconds: 1000),
        max: const Duration(seconds: 60),
        jitterFraction: 0.25,
        rng: Random(42),
      );

      for (var i = 0; i < 50; i++) {
        final delay = policy.delayFor(1).inMilliseconds;
        expect(delay, greaterThanOrEqualTo(750));
        expect(delay, lessThanOrEqualTo(1250));
      }

      for (var i = 0; i < 50; i++) {
        final delay = policy.delayFor(3).inMilliseconds;
        expect(delay, greaterThanOrEqualTo(3000));
        expect(delay, lessThanOrEqualTo(5000));
      }
    });

    test('Test 3: Large retry_count (10^6) does not cause integer overflow or negative duration', () {
      final policy = BackoffPolicy(
        base: const Duration(seconds: 1),
        max: const Duration(minutes: 15),
        jitterFraction: 0,
      );

      final delay = policy.delayFor(1000000);
      expect(delay, equals(const Duration(minutes: 15)), reason: 'Exponential shift clamped without overflow');
      expect(delay.isNegative, isFalse);
    });
  });
}
