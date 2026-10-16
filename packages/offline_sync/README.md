# 🛰️ orbit_offline

**The offline-first sync engine for Flutter and Dart apps that *just works*.**

Your app works 100% offline. Instant saves. Zero loading spinners. When internet returns, Orbit syncs everything with your cloud server invisibly in the background.

Works with **any backend** (Node.js, Python, Go, Ruby, PHP, Java) — no special cloud database required.

---

## 💡 What is Orbit Offline? (In Plain English)

Have you ever filled out a form, entered an elevator or subway, tapped **Submit**, and lost everything because the loading spinner timed out?

**Orbit Offline fixes that forever:**

1. **Tap Save = Instant Save:** Your app saves changes to local storage in 1 millisecond. No waiting on slow networks.
2. **Invisible Background Sync:** When Wi-Fi or cellular comes back (even hours later), Orbit sends the changes to your server automatically.
3. **No Lost Work:** If two people edit the same document at the same time, Orbit blends their changes together intelligently so nobody loses their input.

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

## ⚡ 3-Step Beginner Quickstart

You don't need a PhD in distributed systems. You only need 3 lines of code:

### 1. Add Dependency

In your Flutter app's `pubspec.yaml`:

```yaml
dependencies:
  orbit_offline: ^0.1.0 # (or path: packages/offline_sync)
  sqlite3_flutter_libs: ^0.5.24 # native sqlite engine for mobile
  path_provider: ^2.1.2
```

### 2. Save and Sync Data

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

  // 2. Define your table in 1 line (no code-gen or complex models needed!)
  await orbit.registerTable('todos', {
    'title': 'TEXT NOT NULL',
    'is_done': 'INTEGER NOT NULL DEFAULT 0',
  });

  // 3. Save! Works 100% offline or online
  await orbit.save(
    entity: 'todos',
    data: {'title': 'Buy groceries', 'is_done': 0},
  );

  // 4. Listen to live updates in your Flutter UI
  orbit.watch('SELECT * FROM todos').listen((todos) {
    print('Current todos: $todos');
  });
}
```

---

## 🎯 Choose Your Sync Mode (As Simple as 1, 2, 3)

Orbit comes with 3 ready-to-use profiles tailored to your app type:

| Profile | Real-World App Example | How Conflicts Are Handled |
| :--- | :--- | :--- |
| **`SyncProfile.basic`** | **Personal Notes & Fitness Tracker** | Last person to save wins. Simplest setup. |
| **`SyncProfile.standard`** *(Default)* | **Shared Grocery List & Trello boards** | **Smart Auto-Merge:** If Alice edits the title and Bob checks the checkbox, both edits are saved! |
| **`SyncProfile.enterprise`** | **Invoicing & Banking apps** | Smart merge + relational safety checks. If an invoice has errors, line items pause safely. |

```dart
// Pick your mode in one line:
final orbit = await OrbitClient.initialize(
  databasePath: dbPath,
  serverUrl: 'https://api.yourcompany.com',
  profile: SyncProfile.standard, // or .basic / .enterprise
);
```

---

## 🙋 Frequently Asked Questions (FAQ)

### ❓ Do I need to rewrite my backend server?
**No.** Orbit talks to standard HTTP/JSON REST endpoints (`POST /sync/push`, `GET /sync/pull`). Any server written in Node.js, Python/Django/FastAPI, Go, Rails, Laravel, or Spring works out of the box.

### ❓ Does it drain the user's phone battery?
**No.** Orbit is completely event-driven. It only wakes up when the user saves something new or when network connectivity is restored.

### ❓ What if the phone dies or the app crashes mid-sync?
Orbit uses **checkpoints**. If the app is killed while downloading a 1,000-item sync, it remembers the exact page it was on and resumes from that point next time. It never downloads duplicate data.

### ❓ Do I have to run `flutter pub run build_runner`?
**No!** Orbit offers a **Zero-Codegen Runtime Mode** (Path A). You can query directly with standard SQL. (If your team prefers strictly typed generated classes, an optional code generator is also available).

---

## 📱 Runnable Demo App Included

Try the full Flutter task manager app (offline creation, toggling, deletion, outbox status indicator, and manual sync controls):

```bash
cd example
flutter run
```

---

<details>
<summary><b>🛠️ Advanced Distributed Systems & Architecture Details (For Senior Engineers)</b></summary>

### 10 Distributed Challenges Solved Under the Hood:
1. **Monotonic UUIDv7 IDs:** Avoids client `temp-id` rewrites. Primary keys and foreign keys are valid immediately upon insertion.
2. **Transactional Outbox & Shadow Base:** Local data mutations and outbox records commit in the same SQLite transaction with WAL mode.
3. **Two Generals Packet Loss Resilience:** Client-side idempotency keys prevent duplicate records on dropped HTTP ACK packets.
4. **Mid-Sync Checkpoint Resumption:** Pull streams record transactional pagination cursors per batch.
5. **Selective Parent-Child DAG Holding:** Quarantined parent records pause dependent children without blocking unrelated entity queues.
6. **3-Way Column Auto-Merge:** Merges non-conflicting field updates using shadow base diffs.
7. **Generation-Swap Recovery (HTTP 410):** Automatically clears local state and performs clean resync if server tombstones are purged.
8. **In-Flight Schema Upcasting:** Lazily transforms pending v1 outbox payloads to v2 format prior to network dispatch.
9. **Poison Pill Quarantine (DLQ):** Non-retryable RFC 9457 errors are moved to a dead-letter queue without stalling the engine.
10. **Background Thread Isolation:** Powered by `sqlite_async` on dedicated background worker isolates, keeping the Flutter UI running at 60/120 FPS.

</details>

---

## 📄 License

MIT License. Free for commercial and open-source use.
