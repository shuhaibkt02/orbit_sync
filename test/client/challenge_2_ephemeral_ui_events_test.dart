import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';

void main() {
  late Directory tempDir;
  late OrbitClient client;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('layer5_challenge2_');
    client = await OrbitClient.initialize(
      databasePath: '${tempDir.path}/test.db',
      transport: SyncTransport.inMemory(),
    );
  });

  tearDown(() async {
    await client.close();
    tempDir.deleteSync(recursive: true);
  });

  group('Layer 5 Facade: Challenge 2 Ephemeral UI Events & Scoped SyncJob', () {
    test(
        'sync() returns a SyncJob that can be directly awaited as Future<SyncSummary>',
        () async {
      final job = client.sync();
      expect(job, isA<Future<SyncSummary>>());
      expect(job.syncId, isNotEmpty);

      final summary = await job;
      expect(summary.isSuccess, isTrue);
      expect(summary.hasErrors, isFalse);
    });

    test(
        'syncEvents stream emits correlated SyncStarted and SyncFinished events',
        () async {
      final events = <OrbitSyncEvent>[];
      final sub = client.syncEvents.listen(events.add);

      final summary = await client.sync();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(events.length, greaterThanOrEqualTo(2));
      expect(events.first, isA<SyncStarted>());
      expect(events.last, isA<SyncFinished>());

      final started = events.first as SyncStarted;
      final finished = events.last as SyncFinished;
      expect(started.syncId, equals(finished.syncId));
      expect(finished.summary.applied, equals(summary.applied));

      await sub.cancel();
    });
  });
}
