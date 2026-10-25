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

## 🏗️ How Orbit Works: The 6 Clean Layers

Orbit does not use complex proprietary cloud databases or mandatory code generators. It is designed as a transparent 6-layer pipeline where each layer has a single responsibility:

```text
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │  LAYER 5: Application Facade                                                │
 │  `OrbitClient` & `OrbitTable<T>` • Reactive streams • Type sanitization      │
 ├─────────────────────────────────────────────────────────────────────────────┤
 │  LAYER 6: Observability & Telemetry                                         │
 │  `orbit.observer` • Live SLA warnings • Circular log buffer • KPI counters  │
 ├─────────────────────────────────────────────────────────────────────────────┤
 │  LAYER 1: Local Storage Engine                                              │
 │  SQLite WAL • Transactional Outbox • 0ms instant local writes • UUIDv7      │
 ├─────────────────────────────────────────────────────────────────────────────┤
 │  LAYER 3: Connectivity & Flap Guard                                         │
 │  3s flap debounce • Captive portal canary probes • Instant app resume wakeup│
 ├─────────────────────────────────────────────────────────────────────────────┤
 │  LAYER 2: Consensus & Outbox Replayer                                       │
 │  FIFO queue • Exponential backoff with jitter • Poison pill (DLQ) isolation │
 ├─────────────────────────────────────────────────────────────────────────────┤
 │  LAYER 4: Transport & REST Gateway                                          │
 │  Host Dio/Http adapter • Pure domain JSON (no metadata leaks) • Rate limits │
 └─────────────────────────────────────────────────────────────────────────────┘
                                       │
                                       ▼
                       YOUR EXISTING REST BACKEND
                       (Node.js, Django, Go, Rails, Spring Boot)
```

| Layer | Responsibility | Developer Touchpoint |
| :--- | :--- | :--- |
| **Layer 5: Application Facade** | High-level Flutter API. Provides typed tables (`OrbitTable<T>`), automated SQLite type sanitization, and debounced reactive streams (`watch()`). | `orbit.registerTypedTable<Task>(...)` |
| **Layer 6: Observability** | System telemetry radar. Broadcasts 14 typed events (`onOnline`, `onSlaBreached`), circular log buffer, and dashboard summary streams. | `orbit.observer.events` & `orbit.watchSummary()` |
| **Layer 1: Local Storage** | Fast local persistence. Writes data to SQLite WAL in 0ms with monotonic UUIDv7 keys and atomic outbox envelopes (`_sync_outbox`). | `table.save(item)` |
| **Layer 3: Connectivity** | Smart network monitor. 3s flap guard prevents radio thrashing; canary HTTP probes detect captive portals (airport/hotel logins). | `orbit.simulateOffline` (for testing) |
| **Layer 2: Consensus** | Ordered outbox dispatcher. Replays mutations sequentially (FIFO) with exponential backoff; quarantines poison pills (HTTP 422) to DLQ without blocking other queues. | `orbit.sync()` & `orbit.retryAllFailed()` |
| **Layer 4: Transport** | REST HTTP pipe. Uses your existing `Dio` or `http.Client`. Keeps outbox metadata strictly in HTTP headers so server request bodies stay 100% pure JSON. | `httpClient: myDio` |

### How Data Moves in 3 Steps:
1. **User saves offline:** `Layer 5` sanitizes the data $\to$ `Layer 1` commits to local SQLite table and outbox in **1 millisecond**. Zero spinners.
2. **Signal returns:** `Layer 3` verifies genuine internet reachability $\to$ wakes up `Layer 2`.
3. **Seamless sync:** `Layer 2` reads pending mutations in FIFO order $\to$ `Layer 4` sends standard HTTP requests (`POST /tasks`) via your app's Dio $\to$ `Layer 6` updates the live UI counters.

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
