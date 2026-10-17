# 🛰️ Orbit Offline

**The offline-first sync engine for Flutter and Dart that *just works*.**

Your app works 100% offline. Instant local saves. Zero loading spinners. When the internet returns, Orbit syncs everything with your cloud server invisibly in the background.

Works with **any backend** (Node.js, Python, Go, Ruby, PHP, Java, C#) — no specialized cloud databases or proprietary servers required.

---

## 💡 What Problem Does Orbit Solve?

### The Traditional App Problem:
> You build an app. A user enters an order or fills a form, walks into an elevator or subway, taps **Submit**, and the app shows a spinning loader for 30 seconds before crashing with `"Connection Timeout"`. All user input is lost.

### The Business SLA Problem:
> Your manager says: *"In our business, transactions made today MUST sync to the server today within 1 hour. If automated sync fails because of bad network or server errors, the manager needs a dashboard on their phone showing what failed, why it failed, and a button to retry or override."*

### How Orbit Solves Both:
1. **Instant Saves (0ms delay):** When the user taps Save, data is saved locally to SQLite in 1 millisecond. No spinners.
2. **Invisible Background Sync:** When Wi-Fi or cellular returns, Orbit quietly uploads changes to your backend.
3. **Zero-SQL Admin Dashboard:** Even a junior developer can build a complete Sync Center in 15 lines of Flutter code to inspect pending items, monitor 1-hour business SLAs, and trigger manual retries with zero SQL queries.

```text
  📱 User taps "Save"
         │
         ▼
  ⚡ Saved instantly to local storage (1ms, zero spinner)
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

You don't need distributed systems experience to use Orbit. It takes 3 simple steps:

### 1. Add Dependencies

In your Flutter app's `pubspec.yaml`:

```yaml
dependencies:
  offline_sync: ^0.1.0 # (or path: packages/offline_sync)
  sqlite3_flutter_libs: ^0.5.24 # Native SQLite binaries for mobile/desktop
  path_provider: ^2.1.2
```

### 2. Initialize and Save

```dart
import 'package:offline_sync/offline_sync.dart';
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

  // 2. Register your table in 1 line
  await orbit.registerTable('orders', {
    'customer': 'TEXT NOT NULL',
    'total': 'REAL NOT NULL',
  });

  // 3. Save data! Works 100% offline or online
  await orbit.save(
    entity: 'orders',
    data: {'customer': 'Acme Corp', 'total': 250.0},
  );

  // 4. Read data anytime (100% offline-ready)
  final localOrders = await orbit.restore('orders');
  print('Loaded orders: $localOrders');
}
```

---

## 🎛️ Zero-SQL Sync Dashboard (Built for Developers)

You never have to write SQL queries, inspect internal tables, or parse JSON strings. Orbit provides high-level, strongly-typed Dart functions:

### 1. Real-Time Dashboard KPI Card

Show how many records are pending, synced, or failed in a live Flutter widget:

```dart
StreamBuilder<SyncStatusSummary>(
  stream: orbit.watchSummary(),
  builder: (context, snapshot) {
    final summary = snapshot.data;
    if (summary == null) return const CircularProgressIndicator();

    return Card(
      child: ListTile(
        leading: Icon(
          summary.isClean ? Icons.cloud_done : Icons.cloud_upload,
          color: summary.hasFailures ? Colors.red : Colors.blue,
        ),
        title: Text("Sync Status: ${summary.isClean ? 'All Synced' : 'Syncing...'}"),
        subtitle: Text(
          "Pending: ${summary.pending} | Synced: ${summary.synced} | Failed: ${summary.failed}",
        ),
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

### 3. Why Did a Record Fail? (Full Error Visibility)

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

When a manager or user taps a button in your admin screen to resolve issues, call one clean function:

```dart
// Retry all failed/quarantined items immediately:
await orbit.retryAllFailed(syncNow: true);

// Retry a specific item:
await orbit.retryMutation(item.mutationId, syncNow: true);

// Cancel/discard an invalid local draft:
await orbit.cancelMutation(item.mutationId);

// If you pushed the record through your own custom API, mark it resolved:
await orbit.markSynced(item.mutationId);
```

---

## 🎨 Complete Ready-to-Paste Flutter Sync Screen

Drop this entire widget into your app for an instant, production-grade Sync Center:

```dart
class SyncCenterSheet extends StatelessWidget {
  final OfflineSyncClient orbit;
  const SyncCenterSheet({super.key, required this.orbit});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SyncStatusSummary>(
      stream: orbit.watchSummary(),
      builder: (context, snapshot) {
        final s = snapshot.data;
        if (s == null) return const SizedBox.shrink();

        return Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text("Sync Center", style: Theme.of(context).textTheme.titleLarge),
                  IconButton(
                    icon: const Icon(Icons.sync),
                    onPressed: () => orbit.sync(force: true), // Force instant sync
                  ),
                ],
              ),
              const Divider(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _stat("Pending", s.pending, Colors.orange),
                  _stat("Synced", s.synced, Colors.green),
                  _stat("Failed", s.failed, Colors.red),
                ],
              ),
              const SizedBox(height: 12),
              if (s.hasFailures)
                ElevatedButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text("Retry All Failed Records"),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade700),
                  onPressed: () => orbit.retryAllFailed(syncNow: true),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _stat(String label, int count, Color color) {
    return Column(
      children: [
        Text("$count", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color)),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}
```

---

## 🎯 3 Sync Modes for Any Type of App

Orbit provides 3 pre-tuned profiles:

| Profile | Best For | How It Works |
| :--- | :--- | :--- |
| **`SyncProfile.basic`** | **Personal Notes & To-Do Lists** | Last write wins. The simplest setup. |
| **`SyncProfile.standard`** *(Default)* | **Shared Team Lists & Collaboration** | **Smart Auto-Merge:** If Alice edits the title and Bob checks the box, both edits are preserved without overwriting! |
| **`SyncProfile.enterprise`** | **Invoicing, POS, Banking & Operations** | Auto-merge + relational safety. If an invoice fails, dependent invoice items hold safely in queue. |

```dart
final orbit = await OfflineSyncClient.initialize(
  databasePath: dbPath,
  serverUrl: 'https://api.yourcompany.com',
  profile: SyncProfile.standard, // Pick your profile
);
```

---

## 🛡️ What Happens When Things Go Wrong?

Orbit is engineered with strict resilience guarantees:

1. **Phone battery dies or OS kills app (`SIGKILL`):**  
   Orbit uses SQLite WAL (Write-Ahead Logging). Transactions are atomic: a record is either 100% saved or rolled back cleanly. No corrupt data, ever.
2. **Server returns 422 or 400 (Poison Pill):**  
   Orbit quarantines the bad item to Dead-Letter-Queue (`dlq`) so it doesn't block the rest of your app's sync queue, and notifies your UI.
3. **Flaky Network / Weak Cellular:**  
   Orbit applies exponential backoff with jitter (`1s, 2s, 4s, 8s...`) and listens to OS network connectivity changes to resume instantly when signal returns.
4. **Custom Backend Bypass:**  
   You are never locked in. If you want to sync an outbox record via your own GraphQL, gRPC, or custom HTTP endpoint, you can read the raw payload and call `orbit.markSynced(id)`.

---

## 🧪 Verification & Stability

- **73 Passing Tests:** Unit, crash durability, network failure injection, and E2E emulator tests.
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
