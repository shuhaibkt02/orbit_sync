# 🛰️ Orbit Sync

### Make your Flutter app work 100% offline. Without the headaches.

Instant local saves (0ms). Zero loading spinners. Automatic background cloud sync with your existing REST API.

[![pub package](https://img.shields.io/badge/pub.dev-orbit__sync%20v1.0.0-blue.svg)](https://pub.dev/packages/orbit_sync)
[![test suite](https://img.shields.io/badge/tests-346%20passed%20(100%25)-brightgreen.svg)](https://github.com/shuhaibkt/orbit_sync)
[![license](https://img.shields.io/badge/license-MIT-purple.svg)](https://github.com/shuhaibkt/orbit_sync/blob/main/LICENSE)
[![platform](https://img.shields.io/badge/platforms-Android%20%7C%20iOS%20%7C%20macOS%20%7C%20Web%20%7C%20Linux%20%7C%20Windows-teal.svg)](https://flutter.dev)

---

> [!TIP]
> **Found an edge case or have feedback?**  
> Mobile networks have endless real-world quirks. If you run into any unexpected behavior or have ideas for improvement, let us know on [GitHub Issues](https://github.com/shuhaibkt/orbit_sync/issues). We actively maintain and refine Orbit for the entire Flutter community!

---

## 💡 Why Orbit Sync?

| The Traditional App Problem ❌ | The Orbit Sync Experience ✅ |
| :--- | :--- |
| User enters an order, walks into an elevator, taps **Submit**, and stares at a 30-second spinning loader until it crashes with `"Connection Timeout"`. All entered data is lost. | **Instant 0ms save:** Tapping Save commits directly to local SQLite storage in 1 millisecond. No loading spinners. The user moves on with their day. |
| Building offline sync manually requires hundreds of lines of complex SQL, retry loops, conflict handling, and database triggers. | **Zero SQL, Zero Codegen:** Pass standard Dart models with `fromJson` and `toJson`. Orbit handles the storage, queues, and sync automatically. |
| Proprietary offline databases lock you into their cloud backend, pricing tiers, and hosted database rules. | **Keep your existing backend:** Works with your normal REST API. Zero backend modifications or proprietary plugins needed. |

---

## ⚡ The 3-Step Setup

You don't need distributed systems experience or code generators. Orbit works in 3 simple steps:

### 1. Add Dependencies

In your Flutter app's `pubspec.yaml`:

```yaml
dependencies:
  orbit_sync: ^1.0.0
  sqlite3_flutter_libs: ^0.5.24 # Bundles native SQLite C-libraries with WAL support
  path_provider: ^2.1.2         # Resolves persistent device storage paths
```

### 2. Initialize in 3 Lines of Code

```dart
// 1. Initialize Orbit
final orbit = await OrbitClient.initialize(
  baseUrl: 'https://api.yourcompany.com', // or pass your existing `dio: myDio`!
);

// 2. Define your collection (Pure Dart models, zero raw SQL)
final tasks = orbit.collection<Task>(
  name: 'tasks',
  endpoint: '/tasks',
  fromJson: Task.fromJson,
  toJson: (t) => t.toJson(),
);

// 3. Save! Works 100% offline or online with zero delay (0ms)
await tasks.save(Task(title: 'Ship mobile app to App Store'));
```

### 3. Bind Directly to Flutter UI

Updates automatically in real time whenever local or remote data changes:

```dart
StreamBuilder<List<Task>>(
  stream: tasks.watch(),
  builder: (context, snapshot) {
    final list = snapshot.data ?? [];
    return ListView.builder(
      itemCount: list.length,
      itemBuilder: (context, i) => ListTile(title: Text(list[i].title)),
    );
  },
);
```

---

## 🛠️ Everyday Operations (Save, Query, Delete)

Orbit gives you clean, type-safe methods that just work:

```dart
// CREATE: Saves instantly to local storage and queues background sync
await tasks.save(Task(title: 'Review PR'));

// UPDATE: Updates local storage and auto-merges edits
await tasks.save(task.copyWith(title: 'Review PR #42'));

// DELETE: Removes locally immediately and queues server DELETE
await tasks.delete('task-101');

// SOFT DELETE WITH UNDO: Keeps data temporarily so users can tap "Undo"
await tasks.delete('task-101', undoWindow: const Duration(seconds: 10));

// FAST FILTER QUERY: Filters locally with Dart types (booleans & Dates work seamlessly)
final completed = await tasks.query(
  where: 'status = ?',
  whereArgs: ['DONE'],
  orderBy: 'created_at DESC',
  limit: 20,
);

// WATCH SINGLE ITEM: Listen to live changes on one specific record
tasks.watchById('task-101').listen((task) {
  print('Task status: ${task?.status}');
});
```

---

## 🎯 Flexible Business Rules (Per Collection)

Instead of complex global settings, you can declare business rules per collection in plain English:

```dart
final invoices = orbit.collection<Invoice>(
  name: 'invoices',
  endpoint: '/invoices',
  fromJson: Invoice.fromJson,
  toJson: (i) => i.toJson(),

  // 1. High Priority: Sync critical data (like payments) before background data
  priority: Priority.high, // Critical, High, Normal, Background

  // 2. Business SLA: Alert if transactions stay unsynced past this deadline
  sla: const Duration(hours: 2),

  // 3. Edit Cooling Window: Give users a 2-minute window to fix mistakes before uploading
  coolingTime: const Duration(minutes: 2),

  // 4. Custom Server IDs: If your server uses custom MongoDB `_id` or integer IDs
  idExtractor: (json) => json['invoice_number'] ?? json['id'],
);
```

---

## 🛡️ Built-in Magic (What Orbit Handles For You)

### 1. Smart Conflict Merging
If Alice edits an order's title offline and Bob marks the order paid on the server, Orbit compares both edits against the original snapshot and automatically merges them. Neither teammate loses work.

### 2. Parent-Child Relationship Safety
Creating an Invoice with 3 Invoice Items while offline?  
Orbit assigns temporary local IDs so your local UI updates instantly. When reconnected, Orbit uploads the parent invoice first, receives the server's real ID (`inv_998`), updates the child items automatically, and then uploads them. **Zero foreign-key crashes.**

### 3. Error Isolation (Dead-Letter Queue)
If one bad item fails server validation (e.g., an expired coupon code):
- Orbit moves **only that single item** to an isolated queue (`status: 'dlq'`).
- All other pending orders continue syncing smoothly without getting stuck.
- Your app can notify the user with the exact server error message.

### 4. Smart Battery & Network Protection
- **Flap Guard:** When driving through tunnels or spotty cellular towers, Orbit pauses briefly to avoid draining the user's battery with rapid reconnect attempts.
- **Canary Probe:** Detects hotel and airport Wi-Fi login screens before attempting to sync, preventing corrupted requests.

---

## 🎛️ 15-Line Mobile Sync Center

Build a complete sync dashboard in your Flutter app with zero raw SQL queries:

```dart
// Live sync counters: Pending, Synced, Failed
StreamBuilder<SyncStatusSummary>(
  stream: orbit.watchSummary(),
  builder: (context, snapshot) {
    final s = snapshot.data;
    if (s == null) return const SizedBox.shrink();

    return ListTile(
      leading: Icon(s.isClean ? Icons.cloud_done : Icons.cloud_upload),
      title: Text(s.isClean ? 'All changes synced' : 'Syncing in background...'),
      subtitle: Text('Pending: ${s.pending} | Synced: ${s.synced} | Failed: ${s.failed}'),
      trailing: s.hasFailures
          ? TextButton(
              onPressed: () => orbit.retryAllFailed(syncNow: true),
              child: const Text('Retry Failed'),
            )
          : null,
    );
  },
);
```

---

## 🔄 How Data Moves (The End-to-End Flow)

Here is what happens behind the scenes from the moment a user taps Save to when the data arrives safely in your cloud REST API:

```text
 📱 1. FLUTTER USER INTERFACE
    User taps Save: `tasks.save(Task(title: 'Ship App'))`
    │
    ▼ (Instant 0ms response — UI updates immediately, no spinners)
 ⚡ 2. LOCAL SQLITE DATABASE (WAL Mode)
    ├── tasks table: Saved locally for instant offline display
    └── _sync_outbox table: Queued with Priority, SLA, and Headers
         │
         ▼
 📶 3. NETWORK & CONNECTIVITY CHECK
    ├── [Offline] ──► Preserved safely in SQLite until connection returns
    └── [Online]  ──► Canary probe confirms true internet (not captive portal)
         │
         ▼
 🚦 4. MULTI-LANE CONSENSUS DISPATCHER
    • High Priority queues dispatch first (Critical ──► High ──► Normal)
    • Parents send first; Children wait for server parent ID
    • Smart auto-merge prevents concurrent edits from overwriting
    • Invalid items (HTTP 422) isolate safely to Dead-Letter Queue
         │
         ▼
 🌐 5. TRANSPORT GATEWAY (Standard REST or Dio)
    POST /tasks • PUT /tasks/:id • DELETE /tasks/:id
    Sends 100% pure domain JSON (zero metadata clutter sent to your server)
         │
         ▼
 ☁️ 6. YOUR EXISTING REST BACKEND
    (Any standard REST API: Node, Python, Go, Java, PHP, Rails, etc.)
```

---

## 🧪 Bulletproof Reliability

- **346 Automated Tests (100% Green):** Verified across hard OS process kills (`SIGKILL`), battery death, dirty SQLite WAL reboots, and simulated network failures.
- **Embedded Test Server:** `FakeSyncServer` boots in-process automatically during `dart test` and shuts down cleanly — zero manual setup.
- **Zero Warnings:** Completely verified with `dart analyze` and `dart pub publish --dry-run`.

---

## 📱 Runnable Demo App Included

Want to see Orbit in action? An Apple-inspired task manager app with live sync telemetry, offline toggle, and manual retry controls is included:

```bash
cd example
flutter run
```

---

## 💬 Community, Feedback & Support

No distributed offline sync engine is 100% bug-free across every conceivable device, radio chip, and backend API.

- 🐛 **Found a bug or edge case?** [Open an issue on GitHub](https://github.com/shuhaibkt/orbit_sync/issues).
- 💡 **Feature requests & discussions:** Feel free to share your thoughts and use cases. Every report helps make Orbit better for everyone!

---

## 📄 License

MIT License. Free for commercial and open-source use.
