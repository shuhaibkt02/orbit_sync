import 'dart:io';
import 'package:build/build.dart';
import 'package:build_test/build_test.dart';
import 'package:test/test.dart';
import 'package:offline_sync_generator/builder.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:sync_server/sync_server.dart';

// Test model and simulated generated classes matching generator output
class Task {
  final String id;
  final String title;
  final bool isCompleted;

  Task({required this.id, required this.title, required this.isCompleted});
}

Map<String, dynamic> $TaskToMap(Task entity) => {
  'id': entity.id,
  'title': entity.title,
  'is_completed': entity.isCompleted ? 1 : 0,
};

Task $TaskFromMap(Map<String, dynamic> map) => Task(
  id: map['id'] as String,
  title: map['title'] as String,
  isCompleted: (map['is_completed'] as int) == 1,
);

class $TaskRepository {
  final OfflineSyncClient client;
  final String tableName = 'tasks';
  final String endpoint = '/tasks';

  $TaskRepository(this.client);

  Future<void> registerTable() async {
    await client.registerTable(tableName, {
      'title': 'TEXT NOT NULL',
      'is_completed': 'INTEGER NOT NULL DEFAULT 0',
    });
  }

  Future<String> save(Task task, {String? dependsOnMutationId}) async {
    return await client.save(
      entity: tableName,
      id: task.id,
      data: $TaskToMap(task),
      dependsOnMutationId: dependsOnMutationId,
    );
  }

  Future<void> delete(String id) async {
    await client.delete(entity: tableName, id: id);
  }

  Future<Task?> getById(String id) async {
    final rows = await client.query('SELECT * FROM $tableName WHERE id = ?;', [id]);
    if (rows.isEmpty) return null;
    return $TaskFromMap(rows.first);
  }

  Stream<List<Task>> watchAll() {
    return client.watch('SELECT * FROM $tableName ORDER BY title;').map(
      (rs) => rs.map((r) => $TaskFromMap(r)).toList(),
    );
  }
}

extension $TaskClientExtension on OfflineSyncClient {
  $TaskRepository get tasks => $TaskRepository(this);
}

void main() {
  group('Issue 10: Codegen Companion Packages & Automated Test Generator', () {
    test('Test Case 1: Generator AST Builder parses @SyncEntity and emits type-safe repository code', () async {
      final sources = {
        'offline_sync_annotation|lib/offline_sync_annotation.dart': '''
          library offline_sync_annotation;
          class SyncEntity {
            final String endpoint;
            final String? tableName;
            final String profile;
            const SyncEntity({required this.endpoint, this.tableName, this.profile = 'standard'});
          }
          class PrimaryKey { const PrimaryKey(); }
          class SyncField { final String? name; final bool isIgnored; const SyncField({this.name, this.isIgnored = false}); }
        ''',
        'sample_pkg|lib/task.dart': '''
          import 'package:offline_sync_annotation/offline_sync_annotation.dart';

          @SyncEntity(endpoint: '/tasks', tableName: 'tasks')
          class Task {
            @PrimaryKey()
            final String id;
            final String title;
            final bool isCompleted;

            Task({required this.id, required this.title, required this.isCompleted});
          }
        ''',
      };

      await testBuilder(
        syncEntityBuilder(BuilderOptions.empty),
        sources,
        outputs: {
          'sample_pkg|lib/task.sync.g.dart': decodedMatches(
            allOf([
              contains(r'class $TaskRepository'),
              contains(r'Future<void> registerTable() async'),
              contains(r'Future<String> save(Task entity'),
              contains(r'Stream<List<Task>> watchAll'),
              contains(r'extension $TaskClientExtension on OfflineSyncClient'),
              contains(r'class $TaskSyncTestSuite'),
            ]),
          ),
        },
      );
    });

    test('Test Case 2: Generated Repository executes type-safe CRUD and reactive streaming', () async {
      final tempDir = Directory.systemTemp.createTempSync('codegen_repo_test_');
      final server = await FakeSyncServer.start(port: 0);
      final client = await OfflineSyncClient.initialize(
        databasePath: '${tempDir.path}/app.db',
        serverUrl: server.baseUrl,
      );

      // 1. Register schema via generated repository
      await client.tasks.registerTable();

      // 2. Type-safe save
      final task1 = Task(id: 'task-gen-1', title: 'Buy Groceries', isCompleted: false);
      await client.tasks.save(task1);

      // 3. Type-safe getById
      final retrieved = await client.tasks.getById('task-gen-1');
      expect(retrieved, isNotNull);
      expect(retrieved!.id, 'task-gen-1');
      expect(retrieved.title, 'Buy Groceries');
      expect(retrieved.isCompleted, false);

      // 4. Reactive stream
      final allTasks = await client.tasks.watchAll().first;
      expect(allTasks.length, 1);
      expect(allTasks.first.title, 'Buy Groceries');

      // 5. Type-safe delete
      await client.tasks.delete('task-gen-1');
      final afterDelete = await client.tasks.getById('task-gen-1');
      expect(afterDelete, isNull);

      await client.close();
      await server.stop();
      tempDir.deleteSync(recursive: true);
    });
  });
}
