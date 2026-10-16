# offline_sync

A universal, robust, client-side offline-first synchronization engine for Flutter and Dart.

`offline_sync` solves the hard distributed systems challenges of offline mobile apps—monotonic ID generation, transactional outboxes, Two Generals packet loss, mid-sync crash checkpoints, selective parent-child holding, and multi-client convergence—**without requiring proprietary sync backend infrastructure**.

You can pair it with any standard HTTP/JSON backend written in Node, Go, Rails, Python, or Elixir.

---

## Key Highlights

- **Zero Code Generation:** No `build_runner` or compile-time schema generators. Works directly with standard SQL queries and dynamic runtime tables.
- **Dedicated Background Writer Isolate:** Powered by `sqlite_async` in WAL mode, ensuring UI rendering never stutters or drops frames during heavy database sync writes.
- **Monotonic UUIDv7 Primary Keys:** Eliminates the temporary client ID anti-pattern (`temp-1` -> `srv-1234`). Foreign keys remain consistent locally and globally from the millisecond they are created.
- **Transactional Outbox & Shadow Base:** Guarantees local state mutation and outbox sync intent are committed in a single atomic SQLite transaction.
- **Mid-Sync Crash Recovery:** Pull cursors are checkpointed transactionally per page. If the app is killed by the OS mid-sync, sync resumes from the last completed page without re-fetching data.
- **Selective Holding (DAG Dependencies):** If a parent record mutation fails validation or is quarantined, only its direct dependent children are held. Unrelated entities in the queue continue syncing with zero head-of-line blocking.
- **Poison Pill Isolation (DLQ):** Non-retryable mutations (e.g. schema invalidations) are quarantined to a Dead-Letter Queue without halting the sync queue.
- **In-Flight Schema Migrations:** Upgrades pending outbox payloads dynamically across app releases before they are dequeued.

---

## Installation

Add `offline_sync` to your `pubspec.yaml`:

```yaml
dependencies:
  offline_sync: ^0.1.0
  # For Flutter platforms (iOS, Android, macOS, Linux, Windows), include sqlite3 libraries:
  sqlite3_flutter_libs: ^0.5.24
  path_provider: ^2.1.2
```

---

## Quick Start

### 1. Initialize the Client

```dart
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:offline_sync/offline_sync.dart';

Future<OfflineSyncClient> setupSyncClient() async {
  final docsDir = await getApplicationDocumentsDirectory();
  final dbPath = p.join(docsDir.path, 'app_sync.db');

  final client = await OfflineSyncClient.initialize(
    databasePath: dbPath,
    serverUrl: 'https://api.example.com',
    getAuthToken: () async => 'Bearer secret-jwt-token',
  );

  // Register application entity tables (automatically handles PK and shadow baselines)
  await client.registerTable('tasks', {
    'title': 'TEXT NOT NULL',
    'is_completed': 'INTEGER NOT NULL DEFAULT 0',
    'updated_at': 'TEXT NOT NULL',
  });

  // Optional: Start automatic background polling every 30 seconds
  client.startPeriodicSync(interval: const Duration(seconds: 30));

  return client;
}
```

### 2. Optimistic Writes (Create, Update, Delete)

All mutations automatically generate UUIDv7 IDs (if omitted), commit to the local table, record a shadow baseline for 3-way merge, and queue an atomic outbox envelope:

```dart
// Insert a new task (UUIDv7 is automatically generated)
final taskId = await client.save(
  entity: 'tasks',
  data: {
    'title': 'Ship offline sync engine',
    'is_completed': 0,
    'updated_at': DateTime.now().toUtc().toIso8601String(),
  },
);

// Update existing task
await client.save(
  entity: 'tasks',
  id: taskId,
  data: {
    'id': taskId,
    'title': 'Ship offline sync engine (done!)',
    'is_completed': 1,
    'updated_at': DateTime.now().toUtc().toIso8601String(),
  },
);

// Delete task
await client.delete(entity: 'tasks', id: taskId);
```

### 3. Reactive UI Streams (Zero Codegen)

Subscribe to live table updates using `client.watch()`. Any local write or remote sync pull automatically notifies listeners:

```dart
StreamBuilder<ResultSet>(
  stream: client.watch(
    'SELECT * FROM tasks ORDER BY updated_at DESC',
  ),
  builder: (context, snapshot) {
    if (!snapshot.hasData) return const CircularProgressIndicator();
    final tasks = snapshot.data!;
    return ListView.builder(
      itemCount: tasks.length,
      itemBuilder: (context, index) {
        final task = tasks[index];
        return CheckboxListTile(
          title: Text(task['title'] as String),
          value: (task['is_completed'] as int) == 1,
          onChanged: (val) {
            client.save(
              entity: 'tasks',
              id: task['id'] as String,
              data: {
                'id': task['id'],
                'title': task['title'],
                'is_completed': val == true ? 1 : 0,
                'updated_at': DateTime.now().toUtc().toIso8601String(),
              },
            );
          },
        );
      },
    );
  },
)
```

### 4. Manual Sync & Lifecycle

```dart
// Trigger an immediate bidirectional sync (push local outbox -> pull server changes)
await client.sync();

// Pause background sync when app enters background or goes offline
client.pauseSync();

// Resume background sync when app comes back to foreground or regains connectivity
client.resumeSync();

// Close cleanly on app termination
await client.close();
```

---

## Backend Sync Protocol Contract

`offline_sync` connects to standard RESTful endpoints following this specification:

### 1. Push Changes: `POST /sync/push`

Transmits un-synced local mutations to the server.

- **Headers:**
  - `Idempotency-Key`: Client-generated UUIDv7 for the mutation. Server must deduplicate repeated requests with the same key.
  - `X-App-Version`: Integer app version (e.g., `1`).
  - `Authorization`: Bearer token (if configured).
- **Request Body:**
  ```json
  {
    "mutations": [
      {
        "mutation_id": "018dc325-1100-7000-8000-000000000001",
        "entity_type": "tasks",
        "entity_id": "018dc325-1100-7000-8000-000000000002",
        "action": "upsert",
        "payload": {
          "id": "018dc325-1100-7000-8000-000000000002",
          "title": "Buy milk",
          "is_completed": 0
        },
        "created_at": 1713000000000
      }
    ]
  }
  ```
- **Responses:**
  - `200 OK`: Mutations committed or already applied.
  - `409 Conflict`: Concurrency conflict; client triggers 3-way merge.
  - `422 Unprocessable Content`: RFC 9457 business invariant violation (e.g. `start_time > end_time`). Local optimistic state is rolled back to shadow baseline.
  - `426 Upgrade Required`: Client version is below server version floor. Client halts sync until app is updated.

### 2. Pull Changes: `GET /sync/pull`

Fetches incremental delta changes from the server monotonic change feed.

- **Query Parameters:**
  - `cursor`: Integer cursor indicating the client's last received change sequence (default: `0`).
  - `limit`: Maximum number of records per page (default: `100`).
- **Response Body (`200 OK`):**
  ```json
  {
    "changes": [
      {
        "seq": 101,
        "entity_type": "tasks",
        "entity_id": "018dc325-1100-7000-8000-000000000002",
        "data": {
          "id": "018dc325-1100-7000-8000-000000000002",
          "title": "Buy milk & cookies",
          "is_completed": 1
        },
        "_deleted": false,
        "left_scope": false
      }
    ],
    "next_cursor": 101,
    "has_more": false
  }
  ```
- **Tombstones vs Scope Eviction:**
  - `_deleted: true`: The record was deleted globally. Local record and shadow base are deleted.
  - `left_scope: true`: The record is no longer accessible to the user (e.g. unassigned from a project or permission revoked). Local record is purged without creating a delete tombstone.
- **Generation Reset (`410 Gone`):**
  - If the server has pruned transaction logs past the requested cursor, it returns `410 Gone`. The client executes an atomic generation swap: downloads a fresh base snapshot into a staging table and swaps it into production.

---

## Testing & Chaos Verification

This engine includes a complete standalone acceptance suite in `test/` running against an embedded pure-Dart `FakeSyncServer`. Run the suite anytime with:

```bash
dart test
```

Tests verify:
1. Two Generals socket drops mid-push with idempotency deduplication.
2. Interrupted pull sync with transactional page-cursor resume.
3. Poison pill dead-letter queue routing without head-of-line blocking.
4. Multi-client concurrent 3-way field merge.
5. Invariant validation rejection (RFC 9457) with optimistic rollback.
6. Parent-Child DAG dependency selective holding.
7. Schema migrations on queued in-flight mutations.
8. Server version floor enforcement (`HTTP 426`).

---

## License

MIT License. See [LICENSE](LICENSE) for details.
