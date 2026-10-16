# offline_sync_generator

A `build_runner` code generator and automated test suite builder for `offline_sync`.

## Usage

Add to your `pubspec.yaml`:

```yaml
dependencies:
  offline_sync: ^0.1.0
  offline_sync_annotation: ^0.1.0

dev_dependencies:
  offline_sync_generator: ^0.1.0
  build_runner: ^2.4.0
```

Annotate your model:

```dart
import 'package:offline_sync_annotation/offline_sync_annotation.dart';

@SyncEntity(endpoint: '/tasks', profile: 'standard')
class Task {
  @PrimaryKey()
  final String id;
  final String title;
  final bool isCompleted;

  Task({required this.id, required this.title, required this.isCompleted});
}
```

Run `build_runner`:

```bash
dart run build_runner build
```

This generates `task.sync.g.dart` providing:
- Type-safe repository (`$TaskRepository`)
- Client extension (`client.tasks`)
- Automated test suite generator (`$TaskSyncTestSuite.runTests(...)`)
