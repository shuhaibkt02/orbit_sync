import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:orbit_sync/orbit_sync.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'mock_backend.dart';
import 'models/task.dart';
export 'models/task.dart';
import 'ui/apple_theme.dart';
import 'ui/orbit_app.dart';
import 'ui/widgets/apple_header_bar.dart';
import 'ui/widgets/quick_add_bar.dart';
import 'ui/widgets/task_list_view.dart';
import 'ui/widgets/undo_toast.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark),
  );
  runApp(const OrbitSyncExampleApp());
}

class TaskScreen extends StatefulWidget {
  const TaskScreen({super.key});
  @override
  State<TaskScreen> createState() => _TaskScreenState();
}

class _TaskScreenState extends State<TaskScreen> {
  OrbitClient? _orbit;
  OrbitTable<Task>? _tasks;
  MockBackend? _mockBackend;
  String? _initError;

  TaskFilter _selectedFilter = TaskFilter.all;
  String _searchQuery = '';
  final _searchController = TextEditingController();
  Task? _recentlyDeleted;
  Timer? _undoTimer;

  @override
  void initState() {
    super.initState();
    _initOrbit();
  }

  Future<void> _initOrbit() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final mock = await MockBackend.start();
      _mockBackend = mock;
      final client = await OrbitClient.initialize(
          databasePath: p.join(dir.path, 'orbit_tasks.db'), baseUrl: mock.url);
      final table = client.collection<Task>(
          name: 'tasks',
          endpoint: '/tasks',
          fromJson: Task.fromJson,
          toJson: (t) => t.toJson());
      if (mounted) {
        setState(() {
          _orbit = client;
          _tasks = table;
          _initError = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _initError = e.toString());
      }
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _undoTimer?.cancel();
    _orbit?.close();
    _mockBackend?.stop();
    super.dispose();
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }

  Future<void> _addTask(String title) async {
    if (_tasks == null || title.trim().isEmpty) return;
    try {
      await _tasks!.save(Task(
          title: title.trim(),
          createdAt: DateTime.now().millisecondsSinceEpoch));
    } catch (e) {
      _showError('Failed to save task: $e');
    }
  }

  Future<void> _toggle(Task t, bool done) async {
    if (_tasks == null) return;
    try {
      await _tasks!.save(
          Task(id: t.id, title: t.title, isDone: done, createdAt: t.createdAt));
    } catch (e) {
      _showError('Failed to update task: $e');
    }
  }

  Future<void> _delete(Task t) async {
    if (_tasks == null || t.id == null) return;
    _undoTimer?.cancel();
    setState(() => _recentlyDeleted = t);
    try {
      await _tasks!.delete(t.id!);
      _undoTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _recentlyDeleted = null);
      });
    } catch (e) {
      _showError('Failed to delete task: $e');
    }
  }

  Future<void> _undo() async {
    if (_tasks == null || _recentlyDeleted == null) return;
    final toRestore = _recentlyDeleted!;
    setState(() => _recentlyDeleted = null);
    _undoTimer?.cancel();
    try {
      await _tasks!.save(toRestore);
    } catch (e) {
      _showError('Failed to restore task: $e');
    }
  }

  Future<void> _seedDemo() async {
    if (_tasks == null) return;
    try {
      final samples = [
        '🛒 Buy groceries',
        '🚀 Test airplane mode',
        '📚 Read offline sync docs'
      ];
      for (var i = 0; i < samples.length; i++) {
        await _tasks!.save(Task(
            title: samples[i],
            isDone: i == 0,
            createdAt: DateTime.now().millisecondsSinceEpoch - i * 60000));
      }
    } catch (e) {
      _showError('Failed to seed tasks: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_initError != null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(CupertinoIcons.exclamationmark_triangle,
                  color: Colors.red, size: 48),
              const SizedBox(height: 12),
              Text('Failed to start engine: $_initError'),
              const SizedBox(height: 12),
              CupertinoButton.filled(
                  onPressed: _initOrbit, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    if (_orbit == null || _tasks == null) {
      return const Scaffold(
          body: Center(child: CupertinoActivityIndicator(radius: 14)));
    }

    return Scaffold(
      backgroundColor: AppleTheme.bg(context),
      body: Stack(
        children: [
          TaskListView(
            tasks: _tasks!,
            selectedFilter: _selectedFilter,
            onFilterChanged: (f) => setState(() => _selectedFilter = f),
            searchQuery: _searchQuery,
            searchController: _searchController,
            onSearchChanged: (v) => setState(() => _searchQuery = v),
            onSearchCleared: () {
              _searchController.clear();
              setState(() => _searchQuery = '');
            },
            onToggle: _toggle,
            onDelete: _delete,
            onSelectSuggestion: _addTask,
          ),
          Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AppleHeaderBar(orbit: _orbit!, onSeedDemo: _seedDemo)),
          if (_recentlyDeleted != null)
            Positioned(
                bottom: 96,
                left: 16,
                right: 16,
                child: Center(
                    child: UndoToast(
                        message: 'Task removed',
                        onUndo: _undo,
                        onDismiss: () =>
                            setState(() => _recentlyDeleted = null)))),
          Positioned(
              bottom: MediaQuery.of(context).viewInsets.bottom > 0
                  ? MediaQuery.of(context).viewInsets.bottom + 10
                  : 24,
              left: 16,
              right: 16,
              child: QuickAddBar(onAdd: _addTask)),
        ],
      ),
    );
  }
}
