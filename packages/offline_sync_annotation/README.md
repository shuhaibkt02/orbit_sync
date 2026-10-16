# offline_sync_annotation

Lightweight, zero-dependency annotations for the `offline_sync` offline-first synchronization engine.

## Usage

Add to your `pubspec.yaml`:

```yaml
dependencies:
  offline_sync_annotation: ^0.1.0
```

Annotate your domain entities:

```dart
import 'package:offline_sync_annotation/offline_sync_annotation.dart';

@SyncEntity(endpoint: '/tasks', profile: 'standard')
class Task {
  @PrimaryKey()
  final String id; // UUIDv7
  final String title;
  final bool isCompleted;

  Task({required this.id, required this.title, required this.isCompleted});
}
```

Use with `offline_sync_generator` to generate type-safe repositories and automated offline sync test suites.
