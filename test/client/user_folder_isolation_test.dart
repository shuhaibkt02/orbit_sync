import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';
import 'package:orbit_sync/src/client/services/session_manager.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('orbit_user_isolation_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('Ticket 01: Multi-User Folder Isolation & Path Architecture', () {
    test(
        '1. Path resolver: routes user to orbit/users/<userId>/orbit.db and guest fallback',
        () {
      const sessionManager = SessionManager();

      // Explicit userId
      final u1Path = OrbitClient.resolveDatabasePath(
        appDir: 'databases',
        userId: 'usr_101',
      );
      expect(u1Path, equals('databases/orbit/users/usr_101/orbit.db'));
      expect(
        sessionManager.resolveUserDatabasePath(
            appDir: 'databases', userId: 'usr_101'),
        equals('databases/orbit/users/usr_101/orbit.db'),
      );

      // Guest fallback when userId is null or empty
      final guestPath = OrbitClient.resolveDatabasePath(
        appDir: 'databases',
      );
      expect(guestPath, equals('databases/orbit/guest/orbit.db'));

      final emptyUserPath = OrbitClient.resolveDatabasePath(
        appDir: 'databases',
        userId: '   ',
      );
      expect(emptyUserPath, equals('databases/orbit/guest/orbit.db'));

      // Trailing slash normalization
      final cleanSlashPath = OrbitClient.resolveDatabasePath(
        appDir: '/data/user/app/',
        userId: 'usr_102',
      );
      expect(cleanSlashPath,
          equals('/data/user/app/orbit/users/usr_102/orbit.db'));

      // Backwards compatibility: direct databasePath is honored regardless of userId
      final directPath = OrbitClient.resolveDatabasePath(
        databasePath: '/custom/direct/storage.db',
        userId: 'usr_103',
      );
      expect(directPath, equals('/custom/direct/storage.db'));
    });

    test('2. Multi-user directory creation and folder isolation on disk',
        () async {
      final client1 = await OrbitClient.initialize(
        appDir: tempDir.path,
        userId: 'user_1',
      );
      await client1.registerTable('orders', {'title': 'TEXT'});
      await client1.store('orders', {'id': 'ord_u1', 'title': 'User 1 Order'});

      final client2 = await OrbitClient.initialize(
        appDir: tempDir.path,
        userId: 'user_2',
      );
      await client2.registerTable('orders', {'title': 'TEXT'});
      await client2.store('orders', {'id': 'ord_u2', 'title': 'User 2 Order'});

      // Verify physical directory structure
      final u1Dir = Directory('${tempDir.path}/orbit/users/user_1');
      final u2Dir = Directory('${tempDir.path}/orbit/users/user_2');
      expect(u1Dir.existsSync(), isTrue);
      expect(u2Dir.existsSync(), isTrue);
      expect(File('${tempDir.path}/orbit/users/user_1/orbit.db').existsSync(),
          isTrue);
      expect(File('${tempDir.path}/orbit/users/user_2/orbit.db').existsSync(),
          isTrue);

      // Verify data isolation: User 1 does not see User 2's records or outbox
      final u1Records = await client1.restore('orders');
      expect(u1Records.length, equals(1));
      expect(u1Records.first['id'], equals('ord_u1'));
      final u1Outbox = await client1.getRecords();
      expect(u1Outbox.length, equals(1));
      expect(u1Outbox.first.recordId, equals('ord_u1'));

      // Verify User 2 does not see User 1's records or outbox
      final u2Records = await client2.restore('orders');
      expect(u2Records.length, equals(1));
      expect(u2Records.first['id'], equals('ord_u2'));
      final u2Outbox = await client2.getRecords();
      expect(u2Outbox.length, equals(1));
      expect(u2Outbox.first.recordId, equals('ord_u2'));

      await client1.close();
      await client2.close();
    });

    test(
        '3. switchUser cleanly re-opens target user database while preserving unpushed data',
        () async {
      final client = await OrbitClient.initialize(
        appDir: tempDir.path,
        userId: 'user_1',
      );
      expect(client.currentUserId, equals('user_1'));
      expect(client.userId, equals('user_1'));

      await client.registerTable('orders', {'title': 'TEXT'});

      // User 1 stores unpushed offline orders
      await client
          .store('orders', {'id': 'order_u1_1', 'title': 'User 1 First Draft'});
      await client.store(
          'orders', {'id': 'order_u1_2', 'title': 'User 1 Second Draft'});

      var summary = await client.getSummary();
      expect(summary.pending, equals(2));

      var records = await client.restore('orders');
      expect(records.length, equals(2));

      // Switch to user_2: cleanly closes user_1 SQLite connection and opens user_2
      await client.switchUser('user_2');
      expect(client.currentUserId, equals('user_2'));
      expect(client.userId, equals('user_2'));

      // User 2's isolated database should be clean and empty
      summary = await client.getSummary();
      expect(summary.pending, equals(0));
      records = await client.restore('orders');
      expect(records, isEmpty);

      // User 2 creates their own unpushed offline order
      await client
          .store('orders', {'id': 'order_u2_1', 'title': 'User 2 Solo Draft'});
      summary = await client.getSummary();
      expect(summary.pending, equals(1));
      records = await client.restore('orders');
      expect(records.length, equals(1));
      expect(records.first['id'], equals('order_u2_1'));

      // Switch back to user_1: verify user 1's unpushed data is 100% intact
      await client.switchUser('user_1');
      expect(client.currentUserId, equals('user_1'));

      summary = await client.getSummary();
      expect(summary.pending, equals(2));

      records = await client.restore('orders');
      expect(records.length, equals(2));
      final ids = records.map((r) => r['id']).toSet();
      expect(ids, containsAll(['order_u1_1', 'order_u1_2']));
      expect(ids, isNot(contains('order_u2_1')));

      // Switch back to user_2: verify user 2's unpushed data is 100% intact
      await client.switchUser('user_2');
      expect(client.currentUserId, equals('user_2'));

      summary = await client.getSummary();
      expect(summary.pending, equals(1));

      records = await client.restore('orders');
      expect(records.length, equals(1));
      expect(records.first['id'], equals('order_u2_1'));

      // Verify files for both users exist on disk and were never deleted or overwritten
      final u1DbFile = File('${tempDir.path}/orbit/users/user_1/orbit.db');
      final u2DbFile = File('${tempDir.path}/orbit/users/user_2/orbit.db');
      expect(u1DbFile.existsSync(), isTrue);
      expect(u2DbFile.existsSync(), isTrue);

      await client.close();
    });

    test('4. switchUser preserves registered strongly-typed collection handles',
        () async {
      final client = await OrbitClient.initialize(
        appDir: tempDir.path,
        userId: 'user_1',
      );

      final tasks = client.collection<_TaskItem>(
        name: 'tasks',
        fromJson: _TaskItem.fromJson,
        toJson: (t) => t.toJson(),
      );

      // User 1 creates a task
      await tasks.save(_TaskItem(id: 't_1', title: 'Task for User 1'));
      var u1Tasks = await tasks.query();
      expect(u1Tasks.length, equals(1));
      expect(u1Tasks.first.title, equals('Task for User 1'));

      // Switch to user 2
      await client.switchUser('user_2');

      // Typed table handle now targets user 2's database
      var u2Tasks = await tasks.query();
      expect(u2Tasks, isEmpty);

      await tasks.save(_TaskItem(id: 't_2', title: 'Task for User 2'));
      u2Tasks = await tasks.query();
      expect(u2Tasks.length, equals(1));
      expect(u2Tasks.first.title, equals('Task for User 2'));

      // Switch back to user 1: typed table returns user 1's task
      await client.switchUser('user_1');
      u1Tasks = await tasks.query();
      expect(u1Tasks.length, equals(1));
      expect(u1Tasks.first.title, equals('Task for User 1'));

      await client.close();
    });
  });
}

class _TaskItem {
  final String id;
  final String title;

  _TaskItem({required this.id, required this.title});

  factory _TaskItem.fromJson(Map<String, dynamic> json) => _TaskItem(
        id: json['id'] as String,
        title: json['title'] as String,
      );

  Map<String, dynamic> toJson() => {'id': id, 'title': title};
}
