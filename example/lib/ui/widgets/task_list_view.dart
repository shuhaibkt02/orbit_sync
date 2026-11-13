import 'package:flutter/material.dart';
import 'package:orbit_sync/orbit_sync.dart';
import '../../models/task.dart';
import '../apple_theme.dart';
import 'apple_search_bar.dart';
import 'apple_segmented_control.dart';
import 'task_card.dart';
import 'task_empty_state.dart';

/// Scrollable task list handling deduplication, search filtering, and state grouping.
class TaskListView extends StatelessWidget {
  final OrbitTable<Task> tasks;
  final TaskFilter selectedFilter;
  final ValueChanged<TaskFilter> onFilterChanged;
  final String searchQuery;
  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onSearchCleared;
  final void Function(Task task, bool isDone) onToggle;
  final void Function(Task task) onDelete;
  final ValueChanged<String> onSelectSuggestion;

  const TaskListView({
    super.key,
    required this.tasks,
    required this.selectedFilter,
    required this.onFilterChanged,
    required this.searchQuery,
    required this.searchController,
    required this.onSearchChanged,
    required this.onSearchCleared,
    required this.onToggle,
    required this.onDelete,
    required this.onSelectSuggestion,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<OrbitRecord<Task>>>(
      stream: tasks.watchRecords(),
      builder: (context, snapshot) {
        final raw = snapshot.data ?? [];
        final uniqueMap = <String, OrbitRecord<Task>>{};
        for (final r in raw) {
          final id = r.data.id ?? r.data.title;
          if (!uniqueMap.containsKey(id) || r.status != OrbitSyncStatus.synced) {
            uniqueMap[id] = r;
          }
        }
        final all = uniqueMap.values.toList()
          ..sort((a, b) => a.data.isDone != b.data.isDone
              ? (a.data.isDone ? 1 : -1)
              : b.data.createdAt.compareTo(a.data.createdAt));
        final active = all.where((r) => !r.data.isDone).length;
        final filtered = all.where((r) {
          if (selectedFilter == TaskFilter.active && r.data.isDone) {
            return false;
          }
          if (selectedFilter == TaskFilter.completed && !r.data.isDone) {
            return false;
          }
          return searchQuery.isEmpty ||
              r.data.title.toLowerCase().contains(searchQuery.toLowerCase());
        }).toList();

        return CustomScrollView(
          physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics()),
          slivers: [
            const SliverToBoxAdapter(child: SizedBox(height: 120)),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    AppleSearchBar(
                        controller: searchController,
                        onChanged: onSearchChanged,
                        onClear: onSearchCleared),
                    const SizedBox(height: 12),
                    AppleSegmentedControl<TaskFilter>(
                      items: const {
                        TaskFilter.all: 'All',
                        TaskFilter.active: 'Active',
                        TaskFilter.completed: 'Done'
                      },
                      counts: {
                        TaskFilter.all: all.length,
                        TaskFilter.active: active,
                        TaskFilter.completed: all.length - active
                      },
                      selected: selectedFilter,
                      onSelected: onFilterChanged,
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
            if (filtered.isEmpty)
              SliverFillRemaining(
                  hasScrollBody: false,
                  child: TaskEmptyState(
                      hasAnyTasks: all.isNotEmpty,
                      isSearching: searchQuery.isNotEmpty,
                      onSelectSuggestion: onSelectSuggestion))
            else
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    decoration: BoxDecoration(
                        color: AppleTheme.secondaryBg(context),
                        borderRadius:
                            BorderRadius.circular(AppleTheme.radiusLarge)),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: List.generate(
                          filtered.length,
                          (i) => TaskCard(
                              record: filtered[i],
                              isLast: i == filtered.length - 1,
                              onToggle: (v) => onToggle(filtered[i].data, v),
                              onDelete: () => onDelete(filtered[i].data))),
                    ),
                  ),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 120)),
          ],
        );
      },
    );
  }
}
