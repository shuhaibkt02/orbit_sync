import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';

class TaskItem {
  final String id;
  final String title;
  final bool isCompleted;
  final DateTime dueAt;
  final int priority;

  TaskItem({
    required this.id,
    required this.title,
    required this.isCompleted,
    required this.dueAt,
    this.priority = 1,
  });

  factory TaskItem.fromJson(Map<String, dynamic> j) => TaskItem(
        id: j['id'] as String,
        title: j['title'] as String,
        isCompleted: j['is_completed'] == 1 || j['is_completed'] == true,
        dueAt: j['due_at'] is int
            ? DateTime.fromMillisecondsSinceEpoch(j['due_at'] as int)
            : DateTime.parse(j['due_at'].toString()),
        priority: (j['priority'] as num?)?.toInt() ?? 1,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'is_completed': isCompleted,
        'due_at': dueAt,
        'priority': priority,
      };
}

void main() {
  late String dbPath;
  late OrbitClient client;
  late OrbitTable<TaskItem> tasks;

  setUp(() async {
    dbPath = '${Directory.systemTemp.path}/test_type_sanitized_${DateTime.now().microsecondsSinceEpoch}.db';
    client = await OrbitClient.initialize(
      databasePath: dbPath,
      transport: SyncTransport.inMemory(),
    );

    tasks = client.collection<TaskItem>(
      name: 'tasks',
      endpoint: '/tasks',
      columns: {
        'title': 'TEXT NOT NULL',
        'is_completed': 'INTEGER NOT NULL DEFAULT 0',
        'due_at': 'INTEGER NOT NULL',
        'priority': 'INTEGER NOT NULL DEFAULT 1',
      },
      fromJson: TaskItem.fromJson,
      toJson: (t) => t.toJson(),
    );

    // Seed test records
    await tasks.save(TaskItem(
      id: 'task-1',
      title: 'Submit Expense Report',
      isCompleted: true,
      dueAt: DateTime(2026, 10, 25),
      priority: 3,
    ));

    await tasks.save(TaskItem(
      id: 'task-2',
      title: 'Team Sync Call',
      isCompleted: false,
      dueAt: DateTime(2026, 10, 30),
      priority: 2,
    ));

    await tasks.save(TaskItem(
      id: 'task-3',
      title: 'Code Review PR',
      isCompleted: false,
      dueAt: DateTime(2026, 11, 01),
      priority: 1,
    ));
  });

  tearDown(() async {
    await client.close();
    final f = File(dbPath);
    if (await f.exists()) await f.delete();
  });

  group('Level 2->3 Issue 1: SQLite Type Leakage in whereArgs', () {
    test('1. tasks.query handles Dart booleans transparently (true & false)', () async {
      // Dart boolean true passed directly in whereArgs
      final completed = await tasks.query(
        where: 'is_completed = ?',
        whereArgs: [true], // Must NOT throw ArgumentError: Unsupported type for sqlite: true
      );

      expect(completed.length, equals(1));
      expect(completed.first.id, equals('task-1'));

      // Dart boolean false passed directly in whereArgs
      final pending = await tasks.query(
        where: 'is_completed = ?',
        whereArgs: [false], // Must NOT throw ArgumentError: Unsupported type for sqlite: false
      );

      expect(pending.length, equals(2));
      expect(pending.map((t) => t.id), containsAll(['task-2', 'task-3']));
    });

    test('2. tasks.watch reactively filters using Dart booleans without stream error', () async {
      final stream = tasks.watch(
        where: 'is_completed = ?',
        whereArgs: [true],
      );

      // Verify the stream emits completed tasks without any native SQLite ArgumentError
      final initialEmission = await stream.first;
      expect(initialEmission.length, equals(1));
      expect(initialEmission.first.id, equals('task-1'));
    });

    test('3. tasks.query handles DateTime objects transparently in comparison operators', () async {
      final cutoffDate = DateTime(2026, 10, 28);

      // Querying items due after cutoffDate using DateTime object directly
      final upcomingTasks = await tasks.query(
        where: 'due_at > ?',
        whereArgs: [cutoffDate], // Must be sanitized to millisecondsSinceEpoch
        orderBy: 'due_at ASC',
      );

      expect(upcomingTasks.length, equals(2));
      expect(upcomingTasks.first.id, equals('task-2'));
      expect(upcomingTasks.last.id, equals('task-3'));
    });

    test('4. tasks.query handles complex multi-type whereArgs (bool, DateTime, int, String, null)', () async {
      final targetDate = DateTime(2026, 10, 30);

      final results = await tasks.query(
        where: 'is_completed = ? AND due_at = ? AND priority = ? AND title LIKE ?',
        whereArgs: [
          false,                   // bool
          targetDate,              // DateTime
          2,                       // int
          '%Team%',                // String
        ],
      );

      expect(results.length, equals(1));
      expect(results.first.id, equals('task-2'));
    });

    test('5. Top-level orbit.query and orbit.watch sanitize raw SQL parameters', () async {
      // Calling orbit.query with boolean directly
      final rawRows = await client.query(
        "SELECT id FROM tasks WHERE json_extract(data_json, '\$.is_completed') = ?",
        [true],
      );
      expect(rawRows.length, equals(1));
      expect(rawRows.first['id'], equals('task-1'));

      // Calling orbit.watch with DateTime directly
      final watchResult = await client.watch(
        "SELECT id FROM tasks WHERE json_extract(data_json, '\$.due_at') < ?",
        parameters: [DateTime(2026, 10, 28)],
      ).first;

      expect(watchResult.length, equals(1));
      expect(watchResult.first['id'], equals('task-1'));
    });

    test('6. Regression check: standard SQLite primitives remain untouched', () async {
      final intResult = await tasks.query(where: 'priority = ?', whereArgs: [3]);
      expect(intResult.length, equals(1));

      final stringResult = await tasks.query(where: 'title = ?', whereArgs: ['Code Review PR']);
      expect(stringResult.length, equals(1));

      final nullResult = await tasks.query(where: 'title IS NOT ?', whereArgs: [null]);
      expect(nullResult.length, equals(3));
    });
  });
}
