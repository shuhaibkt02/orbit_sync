import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';

class Note {
  final String id;
  final String content;
  final int version;

  Note({
    required this.id,
    required this.content,
    this.version = 1,
  });

  factory Note.fromJson(Map<String, dynamic> j) => Note(
        id: j['id'] as String,
        content: j['content'] as String,
        version: (j['version'] as num?)?.toInt() ?? 1,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'content': content,
        'version': version,
      };
}

void main() {
  late String dbPath;
  late OrbitClient client;
  late OrbitTable<Note> notes;
  late InMemorySyncTransport transport;

  setUp(() async {
    dbPath =
        '${Directory.systemTemp.path}/test_enhancement_${DateTime.now().microsecondsSinceEpoch}.db';
    transport = SyncTransport.inMemory() as InMemorySyncTransport;

    client = await OrbitClient.initialize(
      databasePath: dbPath,
      baseUrl: 'https://api.notes.corp',
      transport: transport,
    );

    // Register collection cleanly without any column types!
    notes = client.collection<Note>(
      name: 'notes',
      endpoint: '/notes',
      fromJson: Note.fromJson,
      toJson: (n) => n.toJson(),
    );
  });

  tearDown(() async {
    await client.close();
    final f = File(dbPath);
    if (await f.exists()) await f.delete();
  });

  group('Pure JSON Document Store & Outbox Wire Enhancements', () {
    test('1. Cached table re-use: orbit.table<T>("notes") returns same handle',
        () {
      final retrieved = client.table<Note>('notes');
      expect(retrieved, isNotNull);
      expect(retrieved.name, equals('notes'));

      expect(
        () => client.table<Note>('non_existent'),
        throwsA(isA<StateError>()),
      );
    });

    test(
        '2. Custom headers saved to outbox headers_json and dispatched via pushCustom',
        () async {
      await notes.save(
        Note(id: 'note-1', content: 'Initial note'),
        headers: {
          'X-Audit-Reason': 'Created by user',
          'X-Tenant-Id': 'tenant-42'
        },
      );

      // Verify headers were stored in _sync_outbox
      final rows = await client.query(
          'SELECT headers_json FROM _sync_outbox WHERE entity_id = ?',
          ['note-1']);
      expect(rows, isNotEmpty);
      expect(rows.first['headers_json'], contains('X-Audit-Reason'));
      expect(rows.first['headers_json'], contains('tenant-42'));

      // Sync and verify transport received custom headers
      await client.sync();
      expect(transport.customPushes, isNotEmpty);
      final lastPush = transport.customPushes.first;
      expect(lastPush['headers'], isNotNull);
      expect((lastPush['headers'] as Map)['X-Audit-Reason'],
          equals('Created by user'));
      expect((lastPush['headers'] as Map)['X-Tenant-Id'], equals('tenant-42'));
    });

    test(
        '3. Audit Trail: OrbitRecord provides previousData alongside current data',
        () async {
      // 1. Initial save
      await notes.save(Note(id: 'note-audit', content: 'Version 1 Draft'));

      // Initial record: previousData is null
      var records = await notes.watchRecords().first;
      var record = records.firstWhere((r) => r.data.id == 'note-audit');
      expect(record.data.content, equals('Version 1 Draft'));
      expect(record.previousData, isNull);

      // 2. Edit within grace window
      await notes.save(Note(id: 'note-audit', content: 'Version 2 Edited'));

      // Updated record: previousData holds Version 1!
      records = await notes.watchRecords().first;
      record = records.firstWhere((r) => r.data.id == 'note-audit');
      expect(record.data.content, equals('Version 2 Edited'));
      expect(record.previousData, isNotNull);
      expect(record.previousData!.content, equals('Version 1 Draft'));
      expect(record.hasPreviousData, isTrue);
    });

    test('4. Single record detail stream: watchById reactively updates',
        () async {
      await notes.save(Note(id: 'note-detail', content: 'Before'));

      final emissions = <Note?>[];
      final sub = notes.watchById('note-detail').listen(emissions.add);

      while (emissions.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(emissions.first?.content, equals('Before'));

      // Update and verify next emission
      await notes.save(Note(id: 'note-detail', content: 'After'));
      while (emissions.length < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(emissions[1]?.content, equals('After'));
      await sub.cancel();
    });

    test(
        '5. Soft delete with undoWindow preserves row with OrbitSyncStatus.pendingDelete',
        () async {
      await notes.save(Note(id: 'note-del', content: 'To be deleted'));

      // Delete with 10 second undo window
      await notes.delete('note-del', undoWindow: const Duration(seconds: 10));

      // Row must still exist in table, but status must be pendingDelete!
      final records = await notes.watchRecords().first;
      final delRecord = records.firstWhere((r) => r.data.id == 'note-del');
      expect(delRecord.status, equals(OrbitSyncStatus.pendingDelete));
      expect(delRecord.isPendingDelete, isTrue);
    });

    test('6. Facade convenience properties: simulateOffline and isOnline', () {
      expect(client.simulateOffline, isFalse);
      expect(client.isOnline, isTrue);

      client.simulateOffline = true;
      expect(client.simulateOffline, isTrue);
      expect(client.isOnline, isFalse);

      client.simulateOffline = false;
      expect(client.simulateOffline, isFalse);
      expect(client.isOnline, isTrue);
    });

    test(
        '7. Pull-to-refresh race: concurrent sync calls wait on same in-flight job',
        () async {
      transport.simulatedLatency = const Duration(milliseconds: 150);

      await notes.save(Note(id: 'race-note', content: 'Sync race test'));

      // Trigger first sync (in-flight)
      final job1 = client.sync();
      // Trigger second sync immediately (simulating pull-to-refresh while syncing)
      final job2 = client.sync();

      final results = await Future.wait([job1, job2]);
      expect(results[0].applied, equals(results[1].applied));
      expect(results[0].durationMs, equals(results[1].durationMs));
    });

    test(
        '8. Untyped store and delete pass custom headers to outbox and custom pushes',
        () async {
      await client.store(
        'notes',
        {'id': 'untyped-1', 'content': 'Untyped store'},
        url: 'https://api.notes.corp/notes',
        headers: {'X-Custom-Store': 'true'},
      );

      var rows = await client.query(
          'SELECT headers_json FROM _sync_outbox WHERE entity_id = ?',
          ['untyped-1']);
      expect(rows, isNotEmpty);
      expect(rows.first['headers_json'], contains('X-Custom-Store'));

      await client.sync();
      expect(transport.customPushes.any((p) => p['entityId'] == 'untyped-1'),
          isTrue);
      final push = transport.customPushes
          .firstWhere((p) => p['entityId'] == 'untyped-1');
      expect((push['headers'] as Map)['X-Custom-Store'], equals('true'));

      // Delete with custom headers
      await client.delete(
        entity: 'notes',
        id: 'untyped-1',
        url: 'https://api.notes.corp/notes',
        headers: {'X-Custom-Delete': 'true'},
      );

      rows = await client.query(
          "SELECT headers_json FROM _sync_outbox WHERE entity_id = ? AND op = 'delete'",
          ['untyped-1']);
      expect(rows, isNotEmpty);
      expect(rows.first['headers_json'], contains('X-Custom-Delete'));
    });
  });
}
