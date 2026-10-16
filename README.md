# 🛰️ Orbit Offline (Flutter & Dart)

**The offline-first sync engine that makes apps work 100% offline — without the headaches.**

Instant saves. Zero loading spinners. Automatic background cloud sync when internet returns.

---

## 💡 What is Orbit Offline? (In Plain English)

Imagine you're writing a note or filling an order while riding the subway with **no cellular connection**:

1. **You tap Save:** It saves to your phone in 1 millisecond. No waiting, no loading spinners, no "Connection Lost" error screens.
2. **You walk outside:** Orbit detects Wi-Fi or cellular and quietly uploads your changes to your server in the background.
3. **Did a teammate edit the same item?** Orbit automatically blends both edits together so nobody loses their hard work.

```text
  📱 User taps "Save"
         │
         ▼
  ⚡ Saved instantly to local database (0ms delay, no spinner)
         │
         ▼
  📦 Queued safely in local outbox
         │
         ├── 🌐 Online?  ──► Invisibly uploads to your server ☁️
         └── 📴 Offline? ──► Waits safely on device until reconnected
```

---

## ⚡ 30-Second Beginner Quickstart

You don't need to learn complex distributed systems. You only need **`orbit_offline`**.

### 1. Add Dependency

In your Flutter app's `pubspec.yaml`:

```yaml
dependencies:
  orbit_offline: ^0.1.0 # (or path: packages/offline_sync)
  sqlite3_flutter_libs: ^0.5.24 # native SQLite engine
  path_provider: ^2.1.2
```

### 2. Save & Sync Data in 3 Lines of Dart

```dart
import 'package:orbit_offline/orbit_offline.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

void main() async {
  // 1. Initialize Orbit
  final dir = await getApplicationDocumentsDirectory();
  final orbit = await OrbitClient.initialize(
    databasePath: p.join(dir.path, 'app.db'),
    serverUrl: 'https://api.yourcompany.com',
  );

  // 2. Register your table in 1 line (no code-gen or complex classes required!)
  await orbit.registerTable('tasks', {
    'title': 'TEXT NOT NULL',
    'is_done': 'INTEGER NOT NULL DEFAULT 0',
  });

  // 3. Save! Works 100% offline or online
  await orbit.save(
    entity: 'tasks',
    data: {'title': 'Buy groceries', 'is_done': 0},
  );

  // 4. Live UI Updates (Stream updates instantly when data changes)
  orbit.watch('SELECT * FROM tasks').listen((tasks) {
    print('Updated tasks: $tasks');
  });
}
```

---

## 🎯 3 Modes for Any Kind of App

| Profile | Real-World App Example | How Conflicts Are Handled |
| :--- | :--- | :--- |
| **`SyncProfile.basic`** | **Personal Notes & Fitness Tracker** | Last person to save wins. Easiest setup. |
| **`SyncProfile.standard`** *(Default)* | **Shared Todo Lists & Team Apps** | **Smart Auto-Merge:** If Alice edits the title and Bob checks the checkbox, both edits are saved! |
| **`SyncProfile.enterprise`** | **Invoicing & Banking Apps** | Smart merge + relational safety checks. If an invoice fails validation, child items wait safely. |

---

## 📂 Repository Guide (Why is it structured like this?)

This repository is built as a **standard Flutter Monorepo** (just like `drift`, `freezed`, and `flutter_bloc`):

```text
offline_plugin/
├── packages/
│   ├── offline_sync/             👈 THE MAIN FLUTTER PACKAGE (Start here!)
│   │   ├── lib/                  # OrbitClient & local sync engine
│   │   ├── example/              # Complete runnable Flutter demo app
│   │   └── test/                 # 22 automated unit & integration tests
│   │
│   ├── offline_sync_annotation/  # (Optional) Type-safe annotations for build_runner
│   └── offline_sync_generator/   # (Optional) Code generator for strict typed repos
│
└── tools/
    └── sync_server/              # Local mock server for testing & chaos simulation
```

---

## 📱 Try the Ready-to-Run Example App

We included a complete Flutter UI with offline creation, toggling, deletion, outbox status indicators, and pause/resume sync controls:

```bash
cd packages/offline_sync/example
flutter run
```

---

## 🧪 Running Tests

```bash
# Test the core sync engine (22 tests)
cd packages/offline_sync && dart test

# Test the optional code generator (9 tests)
cd packages/offline_sync_generator && dart test
```

---

## 📄 License

MIT License. Free for open-source and commercial use.
