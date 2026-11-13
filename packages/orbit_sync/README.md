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
  sqlite3_flutter_libs: ^0.5.24 # Required: Native SQLite C-binaries with WAL support
  path_provider: ^2.1.2         # Required: Persistent app database storage path
```

> [!IMPORTANT]
> **Flutter Platform Dependencies:**
> `orbit_sync` is a pure Dart package powered by `sqlite_async`.
> On Flutter (Android, iOS, macOS, Windows, Linux), you **must** include:
> - `sqlite3_flutter_libs`: bundles native SQLite C-libraries with WAL support so queries don't fail at runtime with `Missing native binary`.
> - `path_provider`: resolves your app's persistent documents directory.

### 2. Initialize and Save

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

  // 1. Initialize Orbit (clean & zero-boilerplate)
  final dir = await getApplicationDocumentsDirectory();
  final orbit = await OrbitClient.initialize(
    databasePath: p.join(dir.path, 'app.db'),
    baseUrl: 'https://api.yourcompany.com', // or simply pass `dio: myDio`!
  );

  // 2. Register collection with REST endpoint (Zero-Codegen!)
  final orders = orbit.collection<Order>(
    name: 'orders',
    endpoint: '/orders',
    cacheTtl: const Duration(minutes: 15), // Auto-refreshes when empty or expired
    fromJson: Order.fromJson,
    toJson: (o) => o.toJson(),
  );

  // 3. Save! Works 100% offline or online (0ms delay)
  await orders.save(Order(customer: 'Acme Corp', total: 250.0));

  // 4. Reactive streaming queries with native Dart types (booleans & DateTimes auto-sanitized!)
  orders.watch(
    where: 'total > ?',
    whereArgs: [100.0],
  ).listen((items) {
    print('Orders in local database: ${items.length}');
  });

  // Query with Dart booleans or DateTimes directly (no SQLite type errors!):
  final active = await orders.query(where: 'total > ?', whereArgs: [50.0]);

  // 5. Retrieve table anywhere in your app without re-registering:
  final cachedOrders = orbit.table<Order>('orders');

  // 6. Watch single record reactively:
  cachedOrders.watchById('order-101').listen((order) => print(order?.customer));

  // 7. Explicit push mutations to backend
  await orbit.sync();
}
```

---

## 🛠️ Complete CRUD Recipe (Copy & Paste for Any Flutter App)

Whether building a simple to-do list or an enterprise POS system, this single pattern covers the entire offline-first lifecycle:

```dart
// ==========================================
// 1. CONFIGURE ONCE AT APP STARTUP
// ==========================================
final orders = orbit.collection<Order>(
  name: 'orders',
  endpoint: '/api/v1/orders',
  fromJson: Order.fromJson,
  toJson: (o) => o.toJson(),

  // Optional: Custom REST Verbs & Endpoints
  createMethod: HttpMethod.post,               // Default: POST
  updateMethod: HttpMethod.patch,              // Default: PUT (or PATCH)
  updateEndpoint: '/api/v1/orders/:id',        // Auto-interpolates :id
  deleteMethod: HttpMethod.delete,             // Default: DELETE

  // Pluggable Server ID Harvesting (Postgres integer, Mongo _id, ERP codes):
  idExtractor: (json) => json['order_id'] ?? json['id'] ?? json['data']?['id'],

  // High-performance B-tree Expression Indexes on JSON fields:
  indexes: ['customer_id', 'status', 'created_at'],

  // Custom entity headers:
  headers: {'X-Client-Version': '2.1.0'},
);

// ==========================================
// 2. DAY-TO-DAY CRUD OPERATIONS (0ms delay)
// ==========================================

// CREATE (Instant 0ms local save; zero fake IDs sent to server)
final newId = await orders.save(Order(customer: 'Alice', total: 120.0));

// UPDATE (Auto-coalesces in outbox if still offline)
await orders.save(existingOrder.copyWith(total: 150.0));

// DELETE (Instant local delete + queues REST DELETE)
await orders.delete(orderId);

// ONE-SHOT QUERY (Transparent JSON filtering & pagination)
final pending = await orders.query(
  where: 'status = ? AND total > ?',
  whereArgs: ['PENDING', 50.0],
  limit: 20,
  orderBy: 'created_at DESC',
);

// REACTIVE STREAM (Direct UI binding to Flutter StreamBuilder)
Stream<List<Order>> liveOrders = orders.watch(
  where: 'status = ?',
  whereArgs: ['ACTIVE'],
  orderBy: 'created_at DESC',
);
```

---

## 🕒 Grace Periods & Audit Trails (`holdFor` & `previousData`)

When a user edits an item offline, you can grant an editing grace window before it syncs to the backend:

```dart
// 1. Save with a 5-minute hold (coalesces intermediate edits without network spam)
await orders.save(
  Order(customer: 'Acme Corp', total: 300.0),
  holdFor: const Duration(minutes: 5),
  headers: {'X-Audit-Reason': 'Manager approved override'}, // Persisted into outbox!
);

// 2. Watch records with automatic audit trail
orders.watchRecords().listen((records) {
  for (final record in records) {
    print('Current: ${record.data}');
    if (record.hasPreviousData) {
      print('Changed from: ${record.previousData}');
    }
  }
});
```

---

## 🌐 Enterprise Dio & Interceptor Integration

If your app uses `dio` with automated token refresh interceptors, pass `SyncTransport.dio`:

```dart
final dio = Dio();

// Attach your app's token refresh interceptors
dio.interceptors.add(
  InterceptorsWrapper(
    onError: (DioException error, handler) async {
      if (error.response?.statusCode == 401) {
        final newToken = await authRepository.refreshToken();
        // Retry failed request with new token
        return handler.resolve(await dio.fetch(retryOptions));
      }
      return handler.next(error);
    },
  ),
);

// Initialize Orbit with your custom Dio:
// Option A (One-liner): Automatically inherits dio.options.baseUrl & interceptors
final orbit = await OrbitClient.initialize(
  databasePath: dbPath,
  dio: dio,
);

// Option B: Explicit transport
final orbit = await OrbitClient.initialize(
  databasePath: dbPath,
  transport: SyncTransport.dio(dio: dio),
);
```

---

## 👨‍👩‍👧 Parent-Child Relations & Server ID Harvesting

When a user creates an order with order items offline:
1. Orbit saves the order with a local UUID (e.g., `temp-001`) and order items referencing `order_id: temp-001`.
2. When online, `POST /orders` sends the order. The server returns its generated ID (`{"id": "ord_998"}`).
3. **Automatic ID Harvesting:** Orbit automatically registers `temp-001 -> ord_998`, updates the local SQLite database, and rewrites pending child mutations in the outbox (`/orders/ord_998/items` and `order_id: ord_998`) before they are sent to the server.
4. **Zero Foreign Key Violations (HTTP 422):** Child items are guaranteed to reference the valid server ID.
```

---

## 📦 Pure JSON Document Store & Zero-Pollution Wire

Orbit is engineered as a **Pure JSON Document Store on SQLite WAL** with zero metadata pollution over HTTP:

1. **Zero Schema Migrations or Relational Bloat:** 
   Local tables (`orders`, `invoices`) store rich nested objects directly into `data_json`. Orbit never runs slow dynamic `ALTER TABLE ADD COLUMN` queries.
2. **Auto-Generated Internal Tracking IDs:**
   When a user creates a new record offline with clean JSON (no `id`), Orbit automatically generates an internal tracking ID (UUIDv7), assigns it to local SQLite, and returns `internalId` to Flutter. Your outgoing HTTP payload remains 100% pure and untouched.
3. **Zero URL Duplication:**
   Configure your endpoint once at app startup (`orders = client.collection(name: 'orders', endpoint: '/api/v1/orders')`). Daily CRUD operations (`orders.save(data)`) automatically inherit the URL without repetitive boilerplate.
4. **Pluggable `idExtractor` (Zero Backend Guessing):**
   Compatible with any backend schema without framework magic. If your backend returns MongoDB `_id` or custom SAP `orderNumber`, declare it in 1 line:
   ```dart
   final orders = client.collection(
     name: 'orders',
     endpoint: '/api/v1/orders',
     idExtractor: (json) => json['order_number'] ?? json['id'],
   );
   ```
5. **Transparent JSON Querying & Pagination:**
   Write standard Dart queries with optional limits. Orbit transparently translates field filters to SQLite `json_extract`:
   ```dart
   final active = await orders.query(
     where: 'status = ?',
     whereArgs: ['processing'],
     limit: 20,
     orderBy: 'created_at DESC',
   );
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
final orbit = await OrbitClient.initialize(
  databasePath: dbPath,
  baseUrl: 'https://api.yourcompany.com',
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

- **346 Passing Tests:** Unit tests, process crash durability, network failure injection, concurrency, Dio interceptor integration, ID harvesting, and real-world sync scenarios.
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
