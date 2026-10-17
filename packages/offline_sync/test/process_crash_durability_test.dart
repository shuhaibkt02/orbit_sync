import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:offline_sync/offline_sync.dart';

void main() {
  group('Process Crash & OS SIGKILL Durability', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('sigkill_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('OS SIGKILL mid-write guarantees atomic rollback and zero orphaned outbox records on reopen', () async {
      final dbPath = '${tempDir.path}/crash_durability.db';

      // 1. Initial schema initialization in WAL mode
      final initialStorage = await SyncStorage.open(path: dbPath);
      await initialStorage.registerEntityTable('items', {'name': 'TEXT'});
      await initialStorage.save(entity: 'items', id: 'pre-existing', data: {'name': 'Original Item'});
      await initialStorage.close();

      // 2. Spawn child subprocess that begins writeTransaction and hangs
      String dartBinary = Platform.resolvedExecutable;
      if (dartBinary.contains('flutter_tester')) {
        final flutterDir = File(dartBinary).parent.parent.parent.parent.parent;
        final candidate = '${flutterDir.path}/bin/dart';
        dartBinary = File(candidate).existsSync() ? candidate : 'dart';
      }

      final process = await Process.start(
        dartBinary,
        ['run', 'test/helpers/uncommitted_writer.dart', dbPath],
        mode: ProcessStartMode.normal,
      );

      final lineStream = process.stdout.transform(utf8.decoder).transform(const LineSplitter());
      
      // Wait for child to reach uncommitted state
      await for (final line in lineStream) {
        if (line.contains('WRITE_IN_PROGRESS')) {
          break;
        }
      }

      // 3. HARD KILL the child process mid-transaction with SIGKILL (signal 9)
      final killed = process.kill(ProcessSignal.sigkill);
      expect(killed, isTrue);

      final exitCode = await process.exitCode;
      expect(exitCode, isNot(0), reason: 'Process was terminated with SIGKILL');

      // 4. Reopen database in parent process
      final reopenedStorage = await SyncStorage.open(path: dbPath);

      // Verify SQLite WAL journal recovery & integrity
      final integrityRows = await reopenedStorage.db.getAll('PRAGMA integrity_check;');
      expect(integrityRows.first['integrity_check'], equals('ok'), reason: 'Database integrity preserved');

      // Assert pre-existing data is intact
      final preExisting = await reopenedStorage.db.getAll("SELECT * FROM items WHERE id = 'pre-existing'");
      expect(preExisting.length, equals(1));
      expect(preExisting.first['name'], equals('Original Item'));

      // Assert uncommitted writes were 100% rolled back by WAL recovery
      final rolledBackItem = await reopenedStorage.db.getAll("SELECT * FROM items WHERE id = 'crash-item'");
      expect(rolledBackItem, isEmpty, reason: 'Uncommitted active table write was rolled back');

      final rolledBackOutbox = await reopenedStorage.db.getAll("SELECT * FROM _sync_outbox WHERE entity_id = 'crash-item'");
      expect(rolledBackOutbox, isEmpty, reason: 'Zero orphaned outbox records from terminated process');

      // 5. Verify database accepts new transactions normally
      final newMutId = await reopenedStorage.save(
        entity: 'items',
        id: 'post-crash',
        data: {'name': 'Recovered Item'},
      );
      expect(newMutId, isNotEmpty);

      final postCrashRows = await reopenedStorage.db.getAll("SELECT * FROM items WHERE id = 'post-crash'");
      expect(postCrashRows.length, equals(1));

      await reopenedStorage.close();
    });
  });
}
