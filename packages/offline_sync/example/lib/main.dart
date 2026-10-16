import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:offline_sync/offline_sync.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OfflineSyncExampleApp());
}

class OfflineSyncExampleApp extends StatelessWidget {
  const OfflineSyncExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Offline Sync Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const TaskListScreen(),
    );
  }
}

class TaskListScreen extends StatefulWidget {
  const TaskListScreen({super.key});

  @override
  State<TaskListScreen> createState() => _TaskListScreenState();
}

class _TaskListScreenState extends State<TaskListScreen> {
  OfflineSyncClient? _client;
  bool _isLoading = true;
  bool _isSyncing = false;
  bool _isPaused = false;
  String _statusMessage = 'Initializing database...';
  final TextEditingController _textController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initClient();
  }

  Future<void> _initClient() async {
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final dbPath = p.join(docsDir.path, 'offline_tasks.db');

      final client = await OfflineSyncClient.initialize(
        databasePath: dbPath,
        serverUrl: 'http://127.0.0.1:8080',
      );

      // Register the application business entity table
      await client.registerTable('tasks', {
        'title': 'TEXT NOT NULL',
        'is_completed': 'INTEGER NOT NULL DEFAULT 0',
        'created_at': 'TEXT NOT NULL',
      });

      // Start periodic background sync every 30 seconds
      client.startPeriodicSync(interval: const Duration(seconds: 30));

      if (mounted) {
        setState(() {
          _client = client;
          _isLoading = false;
          _statusMessage = 'Ready (Periodic sync active)';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _statusMessage = 'Initialization error: $e';
        });
      }
    }
  }

  @override
  void dispose() {
    _client?.close();
    _textController.dispose();
    super.dispose();
  }

  Future<void> _triggerManualSync() async {
    if (_client == null || _isSyncing) return;
    setState(() => _isSyncing = true);
    try {
      await _client!.sync();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sync completed successfully')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sync notice (offline/local only): $e'),
            backgroundColor: Colors.orange.shade800,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSyncing = false);
      }
    }
  }

  void _togglePauseSync() {
    if (_client == null) return;
    setState(() {
      if (_isPaused) {
        _client!.resumeSync();
        _isPaused = false;
      } else {
        _client!.pauseSync();
        _isPaused = true;
      }
    });
  }

  Future<void> _addTask() async {
    final title = _textController.text.trim();
    if (title.isEmpty || _client == null) return;

    _textController.clear();
    await _client!.save(
      entity: 'tasks',
      data: {
        'title': title,
        'is_completed': 0,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      },
    );
  }

  Future<void> _toggleTask(Map<String, dynamic> task) async {
    if (_client == null) return;
    final isCompleted = (task['is_completed'] as int) == 1;

    await _client!.save(
      entity: 'tasks',
      id: task['id'] as String,
      data: {
        'id': task['id'],
        'title': task['title'],
        'is_completed': isCompleted ? 0 : 1,
        'created_at': task['created_at'],
      },
    );
  }

  Future<void> _deleteTask(String id) async {
    if (_client == null) return;
    await _client!.delete(entity: 'tasks', id: id);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(_statusMessage),
            ],
          ),
        ),
      );
    }

    final client = _client!;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Offline Sync Tasks'),
        actions: [
          IconButton(
            icon: Icon(_isPaused ? Icons.play_arrow : Icons.pause),
            tooltip: _isPaused ? 'Resume Sync' : 'Pause Sync',
            onPressed: _togglePauseSync,
          ),
          IconButton(
            icon: _isSyncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.sync),
            tooltip: 'Sync Now',
            onPressed: _triggerManualSync,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildOutboxStatusCard(client),
          _buildInputBar(),
          const Divider(height: 1),
          Expanded(child: _buildTaskList(client)),
        ],
      ),
    );
  }

  Widget _buildOutboxStatusCard(OfflineSyncClient client) {
    return StreamBuilder<ResultSet>(
      stream: client.watch(
        "SELECT COUNT(*) as count FROM _sync_outbox WHERE status = 'pending'",
      ),
      builder: (context, snapshot) {
        final pendingCount = snapshot.hasData && snapshot.data!.isNotEmpty
            ? snapshot.data!.first['count'] as int
            : 0;

        return Card(
          margin: const EdgeInsets.all(12),
          color: pendingCount > 0 ? Colors.amber.shade50 : Colors.green.shade50,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(
                  pendingCount > 0 ? Icons.cloud_upload_outlined : Icons.cloud_done,
                  color: pendingCount > 0 ? Colors.amber.shade900 : Colors.green.shade800,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        pendingCount > 0
                            ? '$pendingCount pending mutation(s) in outbox'
                            : 'All mutations synchronized',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: pendingCount > 0
                              ? Colors.amber.shade900
                              : Colors.green.shade900,
                        ),
                      ),
                      Text(
                        _isPaused
                            ? 'Sync is paused'
                            : 'Periodic background sync is active',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildInputBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _textController,
              decoration: const InputDecoration(
                hintText: 'Enter new task (e.g. Test offline mode)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (_) => _addTask(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _addTask,
            icon: const Icon(Icons.add),
            label: const Text('Add'),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskList(OfflineSyncClient client) {
    return StreamBuilder<ResultSet>(
      stream: client.watch(
        'SELECT * FROM tasks ORDER BY created_at DESC',
      ),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final tasks = snapshot.data!;
        if (tasks.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.task_alt, size: 64, color: Colors.grey.shade400),
                const SizedBox(height: 12),
                Text(
                  'No tasks yet. Add one above!',
                  style: TextStyle(color: Colors.grey.shade600),
                ),
              ],
            ),
          );
        }

        return ListView.separated(
          itemCount: tasks.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final task = tasks[index];
            final isCompleted = (task['is_completed'] as int) == 1;

            return ListTile(
              leading: Checkbox(
                value: isCompleted,
                onChanged: (_) => _toggleTask(task),
              ),
              title: Text(
                task['title'] as String,
                style: TextStyle(
                  decoration: isCompleted ? TextDecoration.lineThrough : null,
                  color: isCompleted ? Colors.grey : Colors.black87,
                ),
              ),
              subtitle: Text(
                'ID: ${(task['id'] as String).substring(0, 8)}... • ${task['created_at']}',
                style: const TextStyle(fontSize: 11),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                onPressed: () => _deleteTask(task['id'] as String),
              ),
            );
          },
        );
      },
    );
  }
}
