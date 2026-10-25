import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:orbit_sync/orbit_sync.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OrbitSyncExampleApp());
}

class Task {
  final String? id;
  final String title;
  final bool isDone;
  const Task({this.id, required this.title, this.isDone = false});

  factory Task.fromJson(Map<String, dynamic> j) => Task(
        id: j['id']?.toString(),
        title: j['title'] as String? ?? '',
        isDone: j['is_done'] == 1 || j['is_done'] == true,
      );

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'title': title,
        'is_done': isDone ? 1 : 0,
      };
}

class OrbitSyncExampleApp extends StatelessWidget {
  const OrbitSyncExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Orbit Sync Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.deepPurple, useMaterial3: true),
      home: const TaskScreen(),
    );
  }
}

class TaskScreen extends StatefulWidget {
  const TaskScreen({super.key});
  @override
  State<TaskScreen> createState() => _TaskScreenState();
}

class _TaskScreenState extends State<TaskScreen> {
  OfflineSyncClient? _orbit;
  OrbitTable<Task>? _tasks;
  final _input = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initOrbit();
  }

  Future<void> _initOrbit() async {
    final dir = await getApplicationDocumentsDirectory();
    final client = await OfflineSyncClient.initialize(
      databasePath: p.join(dir.path, 'orbit_tasks.db'),
      serverUrl: 'https://api.example.com',
    );
    await client.registerTable('tasks', {
      'title': 'TEXT NOT NULL',
      'is_done': 'INTEGER NOT NULL DEFAULT 0',
    });
    final table = client.registerTypedTable<Task>(
      name: 'tasks',
      fromJson: Task.fromJson,
      toJson: (t) => t.toJson(),
    );
    if (mounted) setState(() { _orbit = client; _tasks = table; });
  }

  @override
  void dispose() {
    _input.dispose();
    _orbit?.close();
    super.dispose();
  }

  Future<void> _addTask() async {
    final title = _input.text.trim();
    if (title.isEmpty || _tasks == null) return;
    _input.clear();
    await _tasks!.save(Task(title: title));
  }

  @override
  Widget build(BuildContext context) {
    if (_orbit == null || _tasks == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('🛰️ Orbit Sync'),
        actions: [
          StreamBuilder<SyncStatusSummary>(
            stream: _orbit!.watchSummary(),
            builder: (ctx, snap) => Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Chip(
                avatar: Icon(snap.data?.hasFailures == true ? Icons.error : Icons.cloud_done, size: 16),
                label: Text('Pending: ${snap.data?.pending ?? 0}'),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    decoration: const InputDecoration(
                      labelText: 'Add task (works 100% offline)',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _addTask(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(icon: const Icon(Icons.add), onPressed: _addTask),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<List<Task>>(
              stream: _tasks!.watch(orderBy: 'is_done ASC, id DESC'),
              builder: (ctx, snapshot) {
                final list = snapshot.data ?? [];
                if (list.isEmpty) return const Center(child: Text('No tasks yet. Create one offline!'));
                return ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (ctx, i) {
                    final t = list[i];
                    return ListTile(
                      leading: Checkbox(
                        value: t.isDone,
                        onChanged: (v) => _tasks!.save(Task(id: t.id, title: t.title, isDone: v ?? false)),
                      ),
                      title: Text(t.title, style: TextStyle(decoration: t.isDone ? TextDecoration.lineThrough : null)),
                      trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _tasks!.delete(t.id!)),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.sync),
        label: const Text('Sync Now'),
        onPressed: () => _orbit!.sync(),
      ),
    );
  }
}
