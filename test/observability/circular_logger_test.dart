import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';

void main() {
  group('Layer 6 Observability: Circular Logger (Challenge 1)', () {
    test('enforces in-memory capacity cap and evicts oldest entries (FIFO)', () {
      final logger = SyncLogger(capacity: 10, minLevel: LogLevel.debug);
      expect(logger.isEmpty, isTrue);

      for (var i = 1; i <= 15; i++) {
        logger.info('Message $i');
      }

      expect(logger.length, equals(10));
      final logs = logger.dumpLogs();
      expect(logs.length, equals(10));
      expect(logs.first.message, equals('Message 6'));
      expect(logs.last.message, equals('Message 15'));
    });

    test('filters log entries strictly by minimum LogLevel', () {
      final logger = SyncLogger(capacity: 50, minLevel: LogLevel.warn);

      logger.debug('Debug msg');
      logger.info('Info msg');
      expect(logger.isEmpty, isTrue);

      logger.warn('Warning msg');
      logger.error('Error msg');
      expect(logger.length, equals(2));

      // Dynamic level change
      logger.minLevel = LogLevel.debug;
      logger.debug('New debug msg');
      expect(logger.length, equals(3));
      expect(logger.dumpLogs().last.message, equals('New debug msg'));
    });

    test('categorizes and logs all SyncEvent types at correct severity', () {
      final logger = SyncLogger(capacity: 20, minLevel: LogLevel.debug);
      final now = DateTime.now().toUtc();

      logger.logEvent(OnlineEvent(timestamp: now));
      logger.logEvent(OfflineEvent(timestamp: now));
      logger.logEvent(SlaWarningEvent(
        timestamp: now,
        mutationId: 'mut-1',
        entity: 'orders',
        entityId: 'ord-1',
        age: const Duration(minutes: 80),
        sla: const Duration(minutes: 100),
      ));
      logger.logEvent(SlaBreachedEvent(
        timestamp: now,
        mutationId: 'mut-2',
        entity: 'orders',
        entityId: 'ord-2',
        age: const Duration(minutes: 120),
        sla: const Duration(minutes: 100),
      ));
      logger.logEvent(PoisonPillQuarantinedEvent(
        timestamp: now,
        mutationId: 'mut-3',
        entity: 'items',
        entityId: 'it-1',
        reason: 'HTTP 400 Bad Payload',
      ));

      final logs = logger.dumpLogs();
      expect(logs.length, equals(5));
      expect(logs[0].level, equals(LogLevel.info));
      expect(logs[1].level, equals(LogLevel.info));
      expect(logs[2].level, equals(LogLevel.warn));
      expect(logs[3].level, equals(LogLevel.error));
      expect(logs[4].level, equals(LogLevel.error));
    });

    test('dumpLogs returns unmodifiable snapshot and clear resets buffer', () {
      final logger = SyncLogger(capacity: 5, minLevel: LogLevel.info);
      logger.info('Item 1');
      logger.info('Item 2');

      final dump = logger.dumpLogs();
      expect(dump.length, equals(2));

      logger.clear();
      expect(logger.isEmpty, isTrue);
      expect(dump.length, equals(2)); // Original snapshot unaffected
    });
  });
}
