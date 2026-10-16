# Offline Sync for Flutter & Dart

A universal, robust, offline-first synchronization engine for Flutter applications.

Works seamlessly across **iOS, Android, macOS, Windows, Linux, and Web** with zero native platform-channel configuration.

---

## 👋 Beginner Quickstart (30 Seconds)

You don't need to learn complex distributed systems to use this library. You only need **`offline_sync`**.

### 1. Add Dependency

In your Flutter app's `pubspec.yaml`:

```yaml
dependencies:
  offline_sync:
    path: path/to/offline_plugin/packages/offline_sync # or ^0.1.0 from pub.dev
  sqlite3_flutter_libs: ^0.5.24 # native sqlite binaries for iOS/Android
  path_provider: ^2.1.2
```

### 2. Initialize in 3 Lines of Dart

```dart
import 'package:offline_sync/offline_sync.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

// 1. Initialize client
final docs = await getApplicationDocumentsDirectory();
final client = await OfflineSyncClient.initialize(
  databasePath: p.join(docs.path, 'app.db'),
  serverUrl: 'https://api.yourapp.com',
);

// 2. Register your table (no migrations or code-gen required!)
await client.registerTable('tasks', {
  'title': 'TEXT NOT NULL',
  'is_done': 'INTEGER NOT NULL DEFAULT 0',
});

// 3. Save data (works 100% offline — automatically syncs when online)
await client.save(
  entity: 'tasks',
  data: {'title': 'Buy groceries', 'is_done': 0},
);

// 4. Watch live updates in your UI
Stream<ResultSet> tasksStream = client.watch('SELECT * FROM tasks');
```

---

## 📱 Try the Ready-to-Run Example App

We included a complete Flutter UI with offline creation, toggling, deletion, outbox status indicators, and pause/resume sync controls.

```bash
cd packages/offline_sync/example
flutter run
```

---

## 📂 Repository Guide (Why is it structured like this?)

If you are wondering why this repository has multiple folders instead of a single Flutter plugin folder:

This repository is structured as a **standard Flutter Monorepo** (identical to packages like `drift`, `freezed`, and `flutter_bloc`):

```text
offline_plugin/
├── packages/
│   ├── offline_sync/             👈 THE MAIN FLUTTER PACKAGE (Start here!)
│   │   ├── lib/                  # OfflineSyncClient & local sync engine
│   │   ├── example/              # Complete runnable Flutter demo app
│   │   └── test/                 # Test suite
│   │
│   ├── offline_sync_annotation/  # (Optional) Annotations for build_runner
│   └── offline_sync_generator/   # (Optional) Typed code generator
│
├── tools/
│   └── sync_server/              # Local mock server for testing & chaos testing
│
└── docs/                         # In-depth architectural & distributed systems specs
```

### Why not a single `flutter create --template=plugin`?
1. **Code Generators must be separated:** In Dart, tools using `analyzer` and `build_runner` cannot be placed in the runtime app package without bloating your app's bundle size and causing dependency version conflicts.
2. **Pure Dart Package vs Native Plugin:** `offline_sync` runs directly on pure Dart SQLite FFI (`sqlite_async`). It does not need fragile native platform channels (Kotlin/Swift), meaning it never crashes your Android Gradle or iOS CocoaPods builds.

---

## 🎯 Choose Your Style

| Feature | Dynamic Runtime (Recommended) | Typed Code Generation (Optional) |
| :--- | :--- | :--- |
| **Package** | `packages/offline_sync` | `packages/offline_sync_generator` |
| **Setup Time** | **1 minute** | 5 minutes |
| **`build_runner` required?** | ❌ No | ✅ Yes |
| **Best For** | Beginners, rapid prototyping, clean apps | Strict compile-time type safety teams |

---

## 🧪 Running Tests

```bash
# Run core sync engine tests (22 tests)
cd packages/offline_sync && dart test

# Run code generator tests (9 tests)
cd packages/offline_sync_generator && dart test
```
