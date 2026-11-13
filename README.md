# 🛰️ Orbit Sync

**Universal zero-codegen offline-first synchronization engine for Flutter, SQLite, and REST APIs.**

Your Flutter app works 100% offline. Instant local saves (0ms delay). Zero loading spinners. When the device reconnects to Wi-Fi or cellular, Orbit quietly syncs all changes with your REST API in the background.

Works with **any backend** (Node.js, Python, Go, Ruby, PHP, Java, Spring Boot, Django, Express, NestJS, FastAPI) — no proprietary databases or backend plugins required.

---

## 💡 What Problem Does Orbit Solve?

### ❌ The Traditional Problem:
A field agent enters an order, steps into an elevator, taps **Submit**, and the app shows a spinning loading icon for 30 seconds before failing with `"Connection Timeout"`. The user loses all entered data and has to start over.

### ✅ The Orbit Solution:
1. **Instant Saves (0ms):** When the user taps Save, data writes directly to local SQLite storage in 1 millisecond. No loading spinners, no waiting.
2. **Invisible Background Sync:** When internet connectivity returns, Orbit automatically uploads queued mutations in the background.
3. **Smart Auto-Merge:** If two teammates edit different fields of the same record offline, Orbit merges both edits without overwriting anyone's work.
4. **Zero-SQL Mobile Dashboard:** Build a complete Sync Center in a few lines of Flutter code to monitor pending items, alert on overdue syncs, and retry failed items with a single tap.

---

## ⚡ 60-Second Quickstart

You don't need distributed systems experience or code generators to use Orbit. It takes 3 simple steps:

### 1. Add Dependencies

In your Flutter app's `pubspec.yaml`:

```yaml
dependencies:
  orbit_sync: ^1.0.0
  sqlite3_flutter_libs: ^0.5.24 # Required: Native SQLite C-binaries with WAL mode
  path_provider: ^2.1.2         # Required: Persistent app database storage path
```

> [!IMPORTANT]
> **Flutter Platform Requirement:**
> `sqlite3_flutter_libs` bundles native SQLite binaries for Android, iOS, macOS, Windows, and Linux. `path_provider` resolves your app's persistent storage directory.

### 2. Initialize Orbit & Define Collections

```dart
import 'package:flutter/widgets.dart';
import 'package:orbit_sync/orbit_sync.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class Order {
  final String? id;
  final String customer;
  final double total;

  Order({this.id, required this.customer, required this.total});

  factory Order.fromJson(Map<String, dynamic> json) => Order(
        id: json['id'] as String?,
        customer: json['customer'] as String,
        total: (json['total'] as num).toDouble(),
      );

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'customer': customer,
        'total': total,
      };
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Initialize Orbit
  final dir = await getApplicationDocumentsDirectory();
  final orbit = await OrbitClient.initialize(
    databasePath: p.join(dir.path, 'app.db'),
    baseUrl: 'https://api.yourcompany.com', // or pass your existing Dio instance: `dio: myDio`
  );

  // 2. Register Collection (Pure Dart models, Zero SQL)
  final orders = orbit.collection<Order>(
    name: 'orders',
    endpoint: '/orders',
    fromJson: Order.fromJson,
    toJson: (o) => o.toJson(),
    
    // Optional Business Rules:
    priority: Priority.high,                 // Critical, High, Normal, Background
    sla: const Duration(hours: 1),           // Alert if unsynced for longer than 1 hour
    coolingTime: const Duration(minutes: 2), // 2-minute editing window before uploading
  );

  // 3. Save! Works 100% offline or online (0ms delay)
  await orders.save(Order(customer: 'Acme Corp', total: 250.0));

  // 4. Reactive UI Stream: Updates instantly whenever local data changes
  orders.watch().listen((items) {
    print('Orders currently in database: ${items.length}');
  });

  // 5. Query with normal Dart types (booleans and DateTimes work automatically)
  final highValue = await orders.query(
    where: 'total > ?',
    whereArgs: [100.0],
    orderBy: 'total DESC',
  );

  // 6. Watch a single record reactively:
  orders.watchById('order-101').listen((order) {
    print('Order updated: ${order?.customer}');
  });
}
```

---

## 🛠️ Complete Everyday CRUD Guide

Orbit gives you simple, type-safe methods for everyday operations:

```dart
// ==========================================
// 1. SAVE / INSERT (Instant 0ms local save)
// ==========================================
final savedId = await orders.save(
  Order(customer: 'Alice', total: 120.0),
  // Optional: Custom HTTP headers for this specific operation
  headers: {'X-Audit-Reason': 'Special discount applied'},
);

// ==========================================
// 2. UPDATE (Updates local database & queues sync)
// ==========================================
await orders.save(existingOrder.copyWith(total: 180.0));

// ==========================================
// 3. DELETE (Instant local delete + queues server DELETE)
// ==========================================
await orders.delete('order-101');

// Optional Soft Delete with Undo Window:
await orders.delete('order-101', undoWindow: const Duration(seconds: 10));

// ==========================================
// 4. ONE-SHOT QUERY (Fast JSON filtering)
// ==========================================
final results = await orders.query(
  where: 'customer = ? AND total > ?',
  whereArgs: ['Alice', 50.0],
  limit: 25,
  orderBy: 'total DESC',
);

// ==========================================
// 5. REACTIVE STREAM (Direct Flutter StreamBuilder binding)
// ==========================================
Stream<List<Order>> stream = orders.watch(
  where: 'total > ?',
  whereArgs: [50.0],
  orderBy: 'total DESC',
);
```

---

## 🎯 Declarative Collection Rules

Instead of rigid global profiles, Orbit allows you to set business rules per collection:

```dart
final invoices = orbit.collection<Invoice>(
  name: 'invoices',
  endpoint: '/api/v1/invoices',
  fromJson: Invoice.fromJson,
  toJson: (i) => i.toJson(),

  // 1. Priority Dispatch
  // Higher priority collections upload before lower priority ones.
  priority: Priority.critical, // Critical, High, Normal, Background

  // 2. Business SLA Deadlines
  // Orbit triggers an alert if a transaction remains unsynced past this duration.
  sla: const Duration(hours: 2),

  // 3. Local Cooling-Off Window
  // Gives users time to make edits or undo actions before network transmission.
  coolingTime: const Duration(minutes: 5),

  // 4. Custom Server ID Harvesting
  // If your server returns SAP codes, MongoDB `_id`, or Postgres integer IDs:
  idExtractor: (json) => json['invoice_number'] ?? json['id'],
);
```

---

## 🛡️ Built-in Resilience Features

### 1. Smart 3-Way Auto-Merge
If Alice updates the order total while offline and Bob marks the order paid on the server, Orbit compares both edits against the original baseline snapshot and automatically merges them. Neither user loses work.

### 2. Parent-Child Relationship Safety
If a user creates an **Invoice** and three **Invoice Items** offline:
1. Orbit assigns temporary local keys so the local database maintains integrity.
2. When online, Orbit sends the parent invoice first.
3. Once the server returns the real ID (`inv_772`), Orbit automatically updates all pending child items before sending them. Zero foreign key errors (HTTP 422).

### 3. Poison-Pill Quarantine (Dead-Letter Queue)
If one bad mutation fails server validation (e.g. an expired coupon code):
- Orbit moves only that specific bad mutation to a Dead-Letter Queue (`status: 'dlq'`).
- Other healthy mutations continue uploading without being blocked.
- Your app's admin dashboard can alert the user with the exact server error message.

### 4. Flap Guard & Captive Portal Detection
- **Flap Guard:** Prevents battery drain when driving through spotty cell towers by using a 3-second debounce on reconnection.
- **Canary Probe:** Verifies actual internet access (detecting hotel and airport login portals) before attempting to sync.

---

## 🎛️ Zero-SQL Mobile Sync Dashboard

Build a full sync management screen in Flutter with no raw SQL queries:

```dart
// 1. Live Counters Stream (Pending, Synced, Failed, DLQ)
StreamBuilder<SyncStatusSummary>(
  stream: orbit.watchSummary(),
  builder: (context, snapshot) {
    final s = snapshot.data;
    if (s == null) return const CircularProgressIndicator();

    return ListTile(
      leading: Icon(s.isClean ? Icons.cloud_done : Icons.cloud_upload),
      title: Text(s.isClean ? 'All Synced' : 'Syncing changes...'),
      subtitle: Text('Pending: ${s.pending} | Synced: ${s.synced} | Failed: ${s.failed}'),
    );
  },
);

// 2. Listen for SLA Breaches (e.g. Offline for over 1 hour)
orbit.observer.onSlaBreached.listen((event) {
  showNotification(
    title: 'Sync Delay Alert',
    body: 'Transaction ${event.mutationId} has not synced within the 1-hour SLA.',
  );
});

// 3. One-Tap Manual Retries
ElevatedButton(
  onPressed: () => orbit.retryAllFailed(syncNow: true),
  child: const Text('Retry All Failed'),
);
```

---

## 🔄 How Data Moves Through Orbit

Here is the complete end-to-end flow from local user interaction to your cloud REST API:

```text
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │                           1. FLUTTER USER INTERFACE                         │
 │                                                                             │
 │    User taps "Save"  ──►  orders.save(Order(customer: 'Acme', total: 250))   │
 └──────────────────────────────────────┬──────────────────────────────────────┘
                                        │ (Instant 0ms save)
                                        ▼
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │                        2. LOCAL SQLITE WAL STORAGE                          │
 │                                                                             │
 │  ┌─────────────────────────────────┐   ┌─────────────────────────────────┐  │
 │  │        orders table (WAL)       │   │       _sync_outbox table        │  │
 │  │  Stores pure JSON document      │   │  Queues pending mutation with   │  │
 │  │  Local UI updates immediately!  │   │  Priority, SLA, and Headers     │  │
 │  └─────────────────────────────────┘   └────────────────┬────────────────┘  │
 └─────────────────────────────────────────────────────────┼───────────────────┘
                                                           │
                                                           ▼
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │                         3. CONNECTIVITY & FLAP GUARD                        │
 │                                                                             │
 │       [Offine?] ──► Safe in SQLite outbox until connection returns          │
 │       [Online?] ──► Canary probe verifies true internet (no captive portal) │
 └──────────────────────────────────────┬──────────────────────────────────────┘
                                        │
                                        ▼
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │                   4. MULTI-LANE CONSENSUS DISPATCHER                        │
 │                                                                             │
 │   • High Priority queues dispatch first (Critical ──► High ──► Normal)      │
 │   • Parent entities send first; Child items await server parent ID          │
 │   • 3-Way Auto-Merge protects concurrent server updates from overwrites     │
 │   • Bad items (HTTP 422) quarantine to DLQ without blocking other queues    │
 └──────────────────────────────────────┬──────────────────────────────────────┘
                                        │
                                        ▼
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │                    5. TRANSPORT LAYER (Standard REST / Dio)                 │
 │                                                                             │
 │        POST /orders • PUT /orders/:id • DELETE /orders/:id                  │
 │        Pure domain JSON payload (zero metadata leaks to your server)        │
 └──────────────────────────────────────┬──────────────────────────────────────┘
                                        │
                                        ▼
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │                          6. YOUR CLOUD REST API                             │
 │           (Node.js, Python, Django, Go, Java, Spring Boot, etc.)            │
 └─────────────────────────────────────────────────────────────────────────────┘
```

---

## 🧪 Verification & Test Suite

- **346 Passing Tests (100% Green):** Complete test coverage across SQLite WAL persistence, crash durability, network failure injection, concurrency, and real-world sync scenarios.
- **Automated Mock Test Server:** In-process test server boots automatically on `dart test` and stops on completion — zero manual setup required.
- **Zero Warnings:** Clean `dart analyze` and clean `dart pub publish --dry-run`.

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
