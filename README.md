# 🛰️ Orbit Offline (Flutter & Dart Monorepo)

**The offline-first sync engine that makes apps work 100% offline — without the headaches.**

Instant local saves (0ms). Zero loading spinners. Automatic background cloud sync when internet returns. Complete zero-SQL developer dashboard and manual override capabilities.

Works with **any backend** (Node.js, Python, Go, Ruby, PHP, Java, .NET) — no proprietary cloud database required.

---

## 💡 What Problem Does Orbit Solve?

### The Traditional Problem:
> A user enters an order or fills a form, walks into an elevator, taps **Submit**, and the app spins for 30 seconds before failing with `"Connection Timeout"`. All user input is lost.

### The Business SLA Problem:
> Your manager says: *"In our business, transactions made today MUST sync within 1 hour. If automated sync fails because of poor connectivity or server errors, the manager needs a dashboard on their phone showing what failed, why it failed, and a button to retry or override."*

### How Orbit Solves Both:
1. **Instant Saves (0ms delay):** When the user taps Save, data is saved locally to SQLite in 1 millisecond. No spinners.
2. **Invisible Background Sync:** When Wi-Fi or cellular returns, Orbit quietly uploads changes to your backend.
3. **Zero-SQL Admin Dashboard:** Even a junior developer can build a complete Sync Center in 15 lines of Flutter code to inspect pending items, monitor 1-hour business SLAs, and trigger manual retries with zero SQL queries.

```text
  📱 User taps "Save"
         │
         ▼
  ⚡ Saved instantly to local database (1ms, zero spinner)
         │
         ▼
  📦 Queued safely in local outbox
         │
         ├── 🌐 Online?  ──► Invisibly uploads to your server ☁️
         └── 📴 Offline? ──► Safely preserved until reconnected
                                 │
                                 ├── Routine reconnect: Auto-syncs seamlessly!
                                 └── Critical failure / SLA breach: Alerts user with 1-tap retry!
```

---

## ⚡ 60-Second Quickstart

### 1. Add Dependency

In your Flutter app's `pubspec.yaml`:

```yaml
dependencies:
  orbit_sync: ^1.0.0 # (or path: packages/orbit_sync)
  sqlite3_flutter_libs: ^0.5.24 # Native SQLite binaries
  path_provider: ^2.1.2
```

### 2. Save & Sync Data in 4 Lines of Dart

```dart
import 'package:orbit_sync/orbit_sync.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Initialize Orbit
  final dir = await getApplicationDocumentsDirectory();
  final orbit = await OfflineSyncClient.initialize(
    databasePath: p.join(dir.path, 'app.db'),
    serverUrl: 'https://api.yourcompany.com',
  );

  // 2. Register your table in 1 line (no code-gen needed!)
  await orbit.registerTable('tasks', {
    'title': 'TEXT NOT NULL',
    'is_done': 'INTEGER NOT NULL DEFAULT 0',
  });

  // 3. Save! Works 100% offline or online
  await orbit.save(
    entity: 'tasks',
    data: {'title': 'Inspect warehouse', 'is_done': 0},
  );

  // 4. Read back offline anytime
  final tasks = await orbit.restore('tasks');
  print('Loaded tasks: $tasks');
}
```

---

## 🎛️ Zero-SQL Sync Dashboard & Overrides

Developers never write raw SQL queries or parse database tables. Orbit provides high-level, strongly-typed Dart functions:

### 1. Real-Time Dashboard KPI Card

Show how many records are pending, synced, or failed in a live Flutter widget:

```dart
StreamBuilder<SyncStatusSummary>(
  stream: orbit.watchSummary(),
  builder: (context, snapshot) {
    final s = snapshot.data;
    if (s == null) return const SizedBox.shrink();

    return Card(
      child: ListTile(
        leading: Icon(
          s.isClean ? Icons.cloud_done : Icons.cloud_upload,
          color: s.hasFailures ? Colors.red : Colors.blue,
        ),
        title: Text("Sync Status: ${s.isClean ? 'All Synced' : 'Syncing...'}"),
        subtitle: Text("Pending: ${s.pending} | Synced: ${s.synced} | Failed: ${s.failed}"),
      ),
    );
  },
);
```

### 2. Business SLA & Stale Data Alerts (e.g. 60 Minutes)

Need to alert the user if transactions haven't synced within a business time window (e.g. 60 minutes)? Just pass a `Duration`:

```dart
// Check for mutations unsynced for longer than 60 minutes:
final staleItems = await orbit.getStaleRecords(maxAge: const Duration(minutes: 60));

// Or listen continuously for SLA breaches to fire local alerts:
orbit.watchStaleRecords(maxAge: const Duration(minutes: 60)).listen((breached) {
  if (breached.isNotEmpty) {
    showNotification(
      title: "Sync SLA Warning",
      body: "${breached.length} transaction(s) have been offline for over 1 hour!",
    );
  }
});
```

### 3. Why Did a Record Fail? (Full Error Transparency)

If a sync fails (e.g., server returned `HTTP 422: Warehouse closed`), Orbit exposes the exact error reason:

```dart
final failures = await orbit.getFailures();

for (final f in failures) {
  print("Failed Record: ${f.entity} #${f.recordId}");
  print("Status Code: ${f.statusCode}"); // e.g. 422 or 500
  print("Server Error: ${f.errorMessage}"); // "Warehouse closed"
  print("Time of failure: ${f.failedAt}");
  print("Original payload: ${f.payload}");
}
```

### 4. One-Tap Manual Overrides

```dart
// Retry all failed/quarantined items immediately:
await orbit.retryAllFailed(syncNow: true);

// Retry a specific item:
await orbit.retryMutation(item.mutationId, syncNow: true);

// Discard an invalid local draft:
await orbit.cancelMutation(item.mutationId);

// Mark resolved if handled via custom API:
await orbit.markSynced(item.mutationId);
```

---

## 🎯 3 Modes for Any Kind of App

| Profile | Real-World App Example | How Conflicts Are Handled |
| :--- | :--- | :--- |
| **`SyncProfile.basic`** | **Personal Notes & Fitness Tracker** | Last person to save wins. Simplest setup. |
| **`SyncProfile.standard`** *(Default)* | **Shared Todo Lists & Team Apps** | **Smart Auto-Merge:** If Alice edits the title and Bob checks the checkbox, both edits are saved! |
| **`SyncProfile.enterprise`** | **Invoicing & Banking Apps** | Smart merge + relational safety checks. If an invoice fails validation, child items wait safely. |

---

## 📂 Repository Structure

This repository is organized as a standard Flutter/Dart monorepo:

```text
orbit_sync/
├── packages/
│   └── orbit_sync/               👈 THE MAIN FLUTTER PACKAGE (Start here!)
│       ├── lib/                  # OrbitClient & local sync engine
│       ├── example/              # Complete runnable Flutter demo app
│       └── test/                 # 152 automated unit, durability & chaos tests
│
├── scripts/
│   └── run_airplane_e2e.sh       # Hardware & Emulator Airplane Mode E2E Test Runner
└── tools/
    └── sync_server/              # Local mock server for testing & chaos simulation
```

---

## 📱 Runnable Demo App Included

Try the full Flutter task manager app with live outbox counters, offline toggle, and manual sync controls:

```bash
cd packages/orbit_sync/example
flutter run
```

---

## 🧪 Running Tests

```bash
# Test the core sync engine (152 tests)
cd packages/orbit_sync && flutter test

# Run analyzer
cd packages/orbit_sync && flutter analyze
```

---

## 📄 License

MIT License. Free for open-source and commercial use.
