/// In-memory topological cycle detection and acyclic DAG validator.
class DagCycleValidator {
  /// Evaluates an existing dependency map [graph] (childMutationId -> parentMutationId)
  /// and checks if adding [childId] -> [parentId] would introduce a cycle.
  /// Throws [ArgumentError] if a cycle is detected.
  static void assertAcyclic({
    required Map<String, String?> graph,
    required String childId,
    required String parentId,
  }) {
    if (childId == parentId) {
      throw ArgumentError(
        'Cyclic dependency detected: mutation $childId cannot depend on itself.',
      );
    }

    // Traverse upwards from parentId to ensure childId is not reachable
    var current = parentId;
    final visited = <String>{childId, parentId};

    while (graph.containsKey(current) && graph[current] != null) {
      final nextParent = graph[current]!;
      if (nextParent == childId) {
        throw ArgumentError(
          'Cyclic dependency detected: $childId -> $parentId -> ... -> $childId forms an illegal cycle.',
        );
      }
      if (visited.contains(nextParent)) {
        // Cycle detected among ancestors
        throw ArgumentError(
          'Cyclic dependency detected in ancestor chain at $nextParent.',
        );
      }
      visited.add(nextParent);
      current = nextParent;
    }
  }

  /// Calculates inherited priority and SLA for prerequisites.
  /// Priority is elevated to child's higher priority; SLA deadline is shortened to child's tighter SLA.
  static ({int priority, int slaSeconds}) inheritPriority({
    required int parentPriority,
    required int parentSlaSeconds,
    required int childPriority,
    required int childSlaSeconds,
  }) {
    return (
      priority: parentPriority > childPriority ? parentPriority : childPriority,
      slaSeconds: parentSlaSeconds < childSlaSeconds ? parentSlaSeconds : childSlaSeconds,
    );
  }
}
