# 🛰️ Orbit Sync

**Universal zero-codegen offline-first synchronization engine for Flutter, SQLite, and REST APIs.**

Your Flutter app works 100% offline. Instant local saves (0ms). Zero loading spinners. When internet returns, Orbit syncs everything with your cloud server invisibly in the background.

Works with **any backend** (Node.js, Python, Go, Ruby, PHP, Java, C#, Spring Boot, Django, Express, NestJS) — no specialized cloud databases or proprietary servers required.

---

## 💡 What Problem Does Orbit Solve?

### The Traditional App Problem:
> A user enters an order or fills a form, walks into an elevator or subway, taps **Submit**, and the app shows a spinning loader for 30 seconds before crashing with `"Connection Timeout"`. All user input is lost.

### The Business SLA Problem:
> Transactions made today MUST sync to the server within 1 hour. If automated sync fails due to bad connectivity or server errors, managers need a mobile dashboard showing what failed, why it failed, and a 1-tap manual override.

### How Orbit Solves Both:
1. **Instant Saves (0ms delay):** When the user taps Save, data is saved locally to SQLite WAL in 1 millisecond. No spinners.
2. **Invisible Background Sync:** When Wi-Fi or cellular returns, Orbit quietly uploads changes to your REST API.
3. **Zero-SQL Admin Dashboard:** Build a complete Sync Center in 15 lines of Flutter code to inspect pending items, monitor 1-hour business SLAs, and trigger manual retries with zero raw SQL queries.

```text
  📱 User taps "Save"
         │
         ▼
  ⚡ Saved instantly to local storage (0ms, zero spinner)
         │
         ▼
  📦 Queued safely in local outbox (SQLite WAL)
         │
         ├── 🌐 Online?  ──► Invisibly uploads to standard REST API ☁️
         └── 📴 Offline? ──► Safely preserved until reconnected
                                 │
                                 ├── Routine reconnect: Auto-syncs seamlessly!
                                 └── Critical failure / SLA breach: Alerts user with 1-tap retry!
```

---

## ⚡ 60-Second Quickstart

You don't need distributed systems experience or code generators to use Orbit. It takes 3 simple steps:

### 1. Add Dependencies

In your Flutter app's `pubspec.yaml`:

```yaml
dependencies:
  orbit_sync: ^1.0.0
  sqlite3_flutter_libs: ^0.5.24 # Native SQLite binaries
  path_provider: ^2.1.2
```

### 2. Initialize and Save

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

  // 2. Register table schema & typed handle (Zero-Codegen!)
  await orbit.registerTable('orders', {
    'customer': 'TEXT NOT NULL',
    'total': 'REAL NOT NULL',
  });
  final orders = orbit.registerTypedTable<Order>(
    name: 'orders',
    fromJson: Order.fromJson,
    toJson: (o) => o.toJson(),
  );

  // 3. Save! Works 100% offline or online (0ms delay)
  await orders.save(Order(customer: 'Acme Corp', total: 250.0));

  // 4. Reactive streaming queries
  orders.watch().listen((items) {
    print('Orders in local database: ${items.length}');
  });
}
```

---

## 🎛️ Zero-SQL Sync Dashboard & Telemetry

You never have to write SQL queries, inspect internal tables, or parse JSON strings. Orbit provides high-level, strongly-typed Dart APIs:

### 1. Real-Time Dashboard KPI Card

Show how many records are pending, synced, or failed in a live Flutter widget:

```dart
StreamBuilder<SyncStatusSummary>(
  stream: orbit.watchSummary(),
  builder: (context, snapshot) {
    final s = snapshot.data;
    if (s == null) return const CircularProgressIndicator();

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

Alert the user if transactions haven't synced within a business time window:

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

### 3. Observability & Event Streaming (`orbit.observer`)

Tap directly into typed runtime events across all system layers:

```dart
// Unified stream:
orbit.observer.events.listen((event) {
  print('Sync telemetry: $event');
});

// Specific event streams:
orbit.observer.onOnline.listen((_) => print('Network back online!'));
orbit.observer.onOffline.listen((_) => print('Switched to offline mode'));
orbit.observer.onSlaBreached.listen((e) => print('SLA breach for mutation: ${e.mutationId}'));
orbit.observer.onConflictDetected.listen((e) => print('Conflict resolved: ${e.entity}'));
orbit.observer.onSyncRejected.listen((e) => print('Server rejected: ${e.errorMessage}'));
```

### 4. One-Tap Manual Overrides

```dart
// Retry all failed/quarantined items immediately:
await orbit.retryAllFailed(syncNow: true);

// Retry a specific item:
await orbit.retryMutation(item.mutationId, syncNow: true);

// Cancel/discard an invalid local draft:
await orbit.cancelMutation(item.mutationId);

// Mark resolved if handled out-of-band:
await orbit.markSynced(item.mutationId);
```

---

## 🎯 3 Sync Profiles for Any App

| Profile | Best For | How It Works |
| :--- | :--- | :--- |
| **`SyncProfile.basic`** | **Personal Notes & To-Do Lists** | Last write wins. The simplest setup. |
| **`SyncProfile.standard`** *(Default)* | **Shared Team Lists & Collaboration** | **Smart Auto-Merge:** If Alice edits the title and Bob checks the box, both edits are preserved without overwriting! |
| **`SyncProfile.enterprise`** | **Invoicing, POS, Banking & Operations** | Auto-merge + relational safety. If an invoice fails, dependent invoice items hold safely in queue. |

```dart
final orbit = await OfflineSyncClient.initialize(
  databasePath: dbPath,
  serverUrl: 'https://api.yourcompany.com',
  profile: SyncProfile.standard,
);
```

---

## 🛡️ Resilience Guarantees

1. **OS Kill (`SIGKILL`) & Battery Death:** Atomic SQLite WAL commits ensure zero orphaned outbox records.
2. **Server 422 / 400 (Poison Pill):** Quarantined to Dead-Letter Queue (DLQ) without blocking other sync queues.
3. **Flaky Radios & Captive Portals:** Asymmetric flap guard (3s reconnect debounce, 0ms disconnect) and canary HTTP probes prevent radio hammering.
4. **Rate Limiting:** Automatic RFC 7231 `Retry-After` header parsing with full jitter backoff on HTTP 429.
5. **Zero Metadata Pollution:** Internal outbox IDs and DAG metadata remain strictly in HTTP headers; request bodies contain 100% pure domain JSON.

---

## 🧪 Verification & Stability

- **152 Passing Tests:** Unit tests, process crash durability, network failure injection, concurrency, and real-world sync scenarios.
- **Physical OS Kill Verified:** Verified across hard Android process terminations with dirty SQLite WAL.
- **Zero Warnings:** Clean `flutter analyze`.

---

## 📱 Runnable Demo App Included

Try the full Flutter task manager app with live outbox counters, offline toggle, and manual sync controls:

```bash
cd example
flutter run
```

---

## 📄 License

MIT License. Free for commercial and open-source use.
