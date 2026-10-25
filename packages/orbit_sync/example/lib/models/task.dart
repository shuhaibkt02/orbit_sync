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
