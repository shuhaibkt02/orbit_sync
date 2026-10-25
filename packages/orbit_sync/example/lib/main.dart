import 'dart:async';
import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:orbit_sync/orbit_sync.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'ui/apple_theme.dart';
import 'mock_backend.dart';
import 'ui/widgets/apple_pressable.dart';
import 'ui/widgets/apple_segmented_control.dart';
import 'ui/widgets/quick_add_bar.dart';
import 'ui/widgets/sync_telemetry_sheet.dart';
import 'ui/widgets/task_card.dart';
import 'ui/widgets/undo_toast.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
    ),
  );
  runApp(const OrbitSyncExampleApp());
}

/// Strongly typed Task entity managed by Orbit Sync engine.
class Task {
  final String? id;
  final String title;
  final bool isDone;
  final int createdAt;

  const Task({
    this.id,
    required this.title,
    this.isDone = false,
    this.createdAt = 0,
  });

  factory Task.fromJson(Map<String, dynamic> j) => Task(
        id: j['id']?.toString(),
        title: j['title'] as String? ?? '',
        isDone: j['is_done'] == 1 || j['is_done'] == true,
        createdAt: (j['created_at'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'title': title,
        'is_done': isDone ? 1 : 0,
        'created_at': createdAt,
      };
}

enum TaskFilter { all, active, completed }

class OrbitSyncExampleApp extends StatelessWidget {
  const OrbitSyncExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Orbit Sync',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF2F2F7),
        colorScheme: const ColorScheme.light(
          primary: AppleTheme.systemBlue,
          surface: Colors.white,
        ),
        fontFamily: '.SF Pro Text',
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF000000),
        colorScheme: const ColorScheme.dark(
          primary: AppleTheme.systemBlueDark,
          surface: Color(0xFF1C1C1E),
        ),
        fontFamily: '.SF Pro Text',
        useMaterial3: true,
      ),
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
  MockBackend? _mockBackend;

  TaskFilter _selectedFilter = TaskFilter.all;
  String _searchQuery = '';
  final _searchController = TextEditingController();

  Task? _recentlyDeletedTask;
  Timer? _undoDismissTimer;

  @override
  void initState() {
    super.initState();
    _initOrbit();
  }

  Future<void> _initOrbit() async {
    final dir = await getApplicationDocumentsDirectory();
    final mockBackend = await MockBackend.start();
    _mockBackend = mockBackend;

    final client = await OfflineSyncClient.initialize(
      databasePath: p.join(dir.path, 'orbit_tasks.db'),
      serverUrl: mockBackend.url,
    );

    await client.registerTable('tasks', {
      'title': 'TEXT NOT NULL',
      'is_done': 'INTEGER NOT NULL DEFAULT 0',
      'created_at': 'INTEGER NOT NULL DEFAULT 0',
    });

    final table = client.registerTypedTable<Task>(
      name: 'tasks',
      fromJson: Task.fromJson,
      toJson: (t) => t.toJson(),
    );

    if (mounted) {
      setState(() {
        _orbit = client;
        _tasks = table;
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _undoDismissTimer?.cancel();
    _orbit?.close();
    _mockBackend?.stop();
    super.dispose();
  }

  Future<void> _addTask(String title) async {
    if (_tasks == null || title.trim().isEmpty) return;
    final task = Task(
      title: title.trim(),
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _tasks!.save(task);
  }

  Future<void> _toggleTask(Task task, bool isDone) async {
    if (_tasks == null) return;
    final updated = Task(
      id: task.id,
      title: task.title,
      isDone: isDone,
      createdAt: task.createdAt,
    );
    await _tasks!.save(updated);
  }

  Future<void> _deleteTask(Task task) async {
    if (_tasks == null || task.id == null) return;
    _undoDismissTimer?.cancel();
    setState(() => _recentlyDeletedTask = task);

    await _tasks!.delete(task.id!);

    _undoDismissTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        setState(() => _recentlyDeletedTask = null);
      }
    });
  }

  Future<void> _undoDelete() async {
    if (_tasks == null || _recentlyDeletedTask == null) return;
    final taskToRestore = _recentlyDeletedTask!;
    setState(() => _recentlyDeletedTask = null);
    _undoDismissTimer?.cancel();

    await _tasks!.save(taskToRestore);
  }

  Future<void> _seedDemoTasks() async {
    if (_tasks == null) return;
    final samples = [
      'Design fluid iOS spring transitions',
      'Verify SQLite WAL durability on airplane mode',
      'Implement multi-master consensus resolution',
    ];
    for (var i = 0; i < samples.length; i++) {
      await _tasks!.save(
        Task(
          title: samples[i],
          isDone: i == 0,
          createdAt: DateTime.now().millisecondsSinceEpoch - (i * 60000),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_orbit == null || _tasks == null) {
      return Scaffold(
        backgroundColor: AppleTheme.bg(context),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CupertinoActivityIndicator(radius: 14),
              const SizedBox(height: 16),
              Text(
                'Initializing Orbit engine...',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: AppleTheme.secondaryLabel(context),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: AppleTheme.bg(context),
      body: Stack(
        children: [
          // Main Scrollable Content
          StreamBuilder<List<OrbitRecord<Task>>>(
            stream: _tasks!.watchRecords(),
            builder: (context, snapshot) {
              final rawRecords = snapshot.data ?? [];

              // Deduplicate records by entity ID
              final uniqueMap = <String, OrbitRecord<Task>>{};
              for (final rec in rawRecords) {
                final id = rec.data.id ?? rec.data.title;
                if (!uniqueMap.containsKey(id) || rec.status != OrbitSyncStatus.synced) {
                  uniqueMap[id] = rec;
                }
              }

              final allList = uniqueMap.values.toList()
                ..sort((a, b) {
                  // Incomplete first, then by createdAt desc
                  if (a.data.isDone != b.data.isDone) {
                    return a.data.isDone ? 1 : -1;
                  }
                  return b.data.createdAt.compareTo(a.data.createdAt);
                });

              final activeCount = allList.where((r) => !r.data.isDone).length;
              final completedCount = allList.where((r) => r.data.isDone).length;

              // Filter by segmented control and search query
              final filteredList = allList.where((r) {
                if (_selectedFilter == TaskFilter.active && r.data.isDone) return false;
                if (_selectedFilter == TaskFilter.completed && !r.data.isDone) return false;
                if (_searchQuery.isNotEmpty &&
                    !r.data.title.toLowerCase().contains(_searchQuery.toLowerCase())) {
                  return false;
                }
                return true;
              }).toList();

              return CustomScrollView(
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                slivers: [
                  // Top Spacing for Floating Header
                  const SliverToBoxAdapter(
                    child: SizedBox(height: 120),
                  ),

                  // Search & Filter Controls
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        children: [
                          _buildSearchBar(context),
                          const SizedBox(height: 12),
                          AppleSegmentedControl<TaskFilter>(
                            items: const {
                              TaskFilter.all: 'All',
                              TaskFilter.active: 'Active',
                              TaskFilter.completed: 'Done',
                            },
                            counts: {
                              TaskFilter.all: allList.length,
                              TaskFilter.active: activeCount,
                              TaskFilter.completed: completedCount,
                            },
                            selected: _selectedFilter,
                            onSelected: (filter) => setState(() => _selectedFilter = filter),
                          ),
                          const SizedBox(height: 16),
                        ],
                      ),
                    ),
                  ),

                  // Task Grouped List or Empty State
                  if (filteredList.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _buildEmptyState(context, hasAnyTasks: allList.isNotEmpty),
                    )
                  else
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(left: 4, bottom: 6),
                              child: Text(
                                _selectedFilter == TaskFilter.completed
                                    ? 'COMPLETED TASKS'
                                    : 'TASKS',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.6,
                                  color: AppleTheme.secondaryLabel(context),
                                ),
                              ),
                            ),
                            Container(
                              decoration: BoxDecoration(
                                color: AppleTheme.secondaryBg(context),
                                borderRadius: BorderRadius.circular(AppleTheme.radiusLarge),
                                border: Border.all(
                                  color: AppleTheme.specularBorder(context),
                                  width: 0.5,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.04),
                                    blurRadius: 10,
                                    offset: const Offset(0, 3),
                                  ),
                                ],
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: Column(
                                children: List.generate(
                                  filteredList.length,
                                  (index) => TaskCard(
                                    record: filteredList[index],
                                    isLast: index == filteredList.length - 1,
                                    onToggle: (val) =>
                                        _toggleTask(filteredList[index].data, val),
                                    onDelete: () =>
                                        _deleteTask(filteredList[index].data),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 120), // Bottom padding for QuickAddBar
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),

          // Translucent Apple Floating Header Bar
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _buildHeaderBar(context),
          ),

          // Floating Undo Toast (Slides in from bottom)
          if (_recentlyDeletedTask != null)
            Positioned(
              bottom: 96,
              left: 16,
              right: 16,
              child: Center(
                child: UndoToast(
                  message: 'Task removed',
                  onUndo: _undoDelete,
                  onDismiss: () => setState(() => _recentlyDeletedTask = null),
                ),
              ),
            ),

          // Apple Reminders Floating Quick-Add Bar
          Positioned(
            bottom: MediaQuery.of(context).viewInsets.bottom > 0
                ? MediaQuery.of(context).viewInsets.bottom + 10
                : 24,
            left: 16,
            right: 16,
            child: QuickAddBar(onAdd: _addTask),
          ),
        ],
      ),
    );
  }

  /// Apple-style frosted glass top bar with live Dynamic Sync Capsule.
  Widget _buildHeaderBar(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: AppleTheme.glass(context, opacity: isDark ? 0.75 : 0.82),
            border: Border(
              bottom: BorderSide(
                color: AppleTheme.divider(context),
                width: 0.5,
              ),
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 16, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Text(
                            'Tasks',
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.6,
                              color: AppleTheme.label(context),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppleTheme.systemIndigo.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(AppleTheme.radiusPill),
                            ),
                            child: const Text(
                              'Orbit',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppleTheme.systemIndigo,
                              ),
                            ),
                          ),
                        ],
                      ),
                      Text(
                        'Offline-First Sync Engine',
                        style: TextStyle(
                          fontSize: 12,
                          letterSpacing: -0.1,
                          color: AppleTheme.secondaryLabel(context),
                        ),
                      ),
                    ],
                  ),

                  // Dynamic Sync Telemetry Capsule
                  StreamBuilder<SyncStatusSummary>(
                    stream: _orbit!.watchSummary(),
                    builder: (context, snapshot) {
                      final summary = snapshot.data;
                      return _buildSyncCapsule(context, summary);
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSyncCapsule(BuildContext context, SyncStatusSummary? summary) {
    final pending = summary?.pending ?? 0;
    final inFlight = summary?.inFlight ?? 0;
    final hasFailures = summary?.hasFailures == true;

    Color capsuleColor;
    Color textColor;
    IconData icon;
    String label;

    if (hasFailures) {
      capsuleColor = AppleTheme.destructive(context);
      textColor = Colors.white;
      icon = CupertinoIcons.exclamationmark_triangle_fill;
      label = '${summary!.failed} Failed';
    } else if (inFlight > 0) {
      capsuleColor = AppleTheme.accent(context);
      textColor = Colors.white;
      icon = CupertinoIcons.arrow_2_circlepath;
      label = 'Syncing';
    } else if (pending > 0) {
      capsuleColor = AppleTheme.warning(context).withValues(alpha: 0.18);
      textColor = AppleTheme.warning(context);
      icon = CupertinoIcons.cloud_upload_fill;
      label = '$pending Pending';
    } else {
      capsuleColor = AppleTheme.success(context).withValues(alpha: 0.16);
      textColor = AppleTheme.success(context);
      icon = CupertinoIcons.checkmark_alt_circle_fill;
      label = 'Synced';
    }

    return ApplePressable(
      onTap: () {
        HapticFeedback.lightImpact();
        SyncTelemetrySheet.show(
          context,
          client: _orbit!,
          onSeedDemo: _seedDemoTasks,
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: capsuleColor,
          borderRadius: BorderRadius.circular(AppleTheme.radiusPill),
          border: Border.all(
            color: textColor.withValues(alpha: 0.3),
            width: 0.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: textColor),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar(BuildContext context) {
    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: AppleTheme.tertiaryBg(context),
        borderRadius: BorderRadius.circular(AppleTheme.radiusMedium),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          Icon(
            CupertinoIcons.search,
            size: 17,
            color: AppleTheme.secondaryLabel(context),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _searchController,
              onChanged: (val) => setState(() => _searchQuery = val),
              style: TextStyle(
                fontSize: 14,
                color: AppleTheme.label(context),
              ),
              decoration: InputDecoration(
                hintText: 'Search tasks...',
                hintStyle: TextStyle(
                  fontSize: 14,
                  color: AppleTheme.secondaryLabel(context),
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          if (_searchQuery.isNotEmpty)
            GestureDetector(
              onTap: () {
                _searchController.clear();
                setState(() => _searchQuery = '');
              },
              child: Icon(
                CupertinoIcons.clear_circled_solid,
                size: 16,
                color: AppleTheme.tertiaryLabel(context),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, {required bool hasAnyTasks}) {
    if (!hasAnyTasks) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: AppleTheme.accent(context).withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  CupertinoIcons.checkmark_shield_fill,
                  size: 36,
                  color: AppleTheme.accent(context),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Ready For Offline Tasks',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.4,
                  color: AppleTheme.label(context),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Everything you create is saved to SQLite immediately and synced when connected.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.4,
                  color: AppleTheme.secondaryLabel(context),
                ),
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  _buildSuggestionChip(context, '🛒 Buy groceries'),
                  _buildSuggestionChip(context, '🚀 Test airplane mode'),
                  _buildSuggestionChip(context, '📚 WWDC design study'),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            CupertinoIcons.tray,
            size: 40,
            color: AppleTheme.tertiaryLabel(context),
          ),
          const SizedBox(height: 12),
          Text(
            _searchQuery.isNotEmpty ? 'No Matching Tasks' : 'No Tasks in this Filter',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppleTheme.secondaryLabel(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuggestionChip(BuildContext context, String title) {
    return ApplePressable(
      onTap: () => _addTask(title),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: AppleTheme.secondaryBg(context),
          borderRadius: BorderRadius.circular(AppleTheme.radiusPill),
          border: Border.all(
            color: AppleTheme.specularBorder(context),
            width: 0.5,
          ),
        ),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: AppleTheme.label(context),
          ),
        ),
      ),
    );
  }
}
