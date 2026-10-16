# Phase 5: The Boundary Division & Code-Gen (build_runner) Strategy

## 1. The Core Dilemma
- **The Developer's World is Dynamic:** Custom models (`User`, `Invoice`, `Task`), arbitrary JSON fields, different API endpoints (`/api/v1/orders`), and custom auth headers.
- **The Plugin Engine is Static:** The SQLite database, transactional outbox, background isolate, retry loops, and conflict algorithms.

---

## 2. The Golden Division of Responsibility

| Component | Who Owns It | How It Works |
| :--- | :---: | :--- |
| **Domain Models & Endpoints** | **Developer** | Defines standard Dart classes annotated with `@SyncEntity(endpoint: '/orders')`. |
| **API Transport / Headers** | **Developer** | Passes their existing `http` or `Dio` client to the plugin. |
| **SQLite Schema & Adapters** | **Code-Gen (`build_runner`)** | Reads `@SyncEntity` and automatically generates type-safe SQLite tables, serialization, and repositories. |
| **Mock Test Fixtures** | **Code-Gen (`build_runner`)** | Automatically generates test mocks and fake sync adapters so developers can test offline behavior instantly. |
| **Transactional Outbox Engine** | **Plugin Runtime** | Guarantees atomic writes (local DB + outbox in 1 transaction). Zero data loss. |
| **Sync Engine & Isolates** | **Plugin Runtime** | Handles background workers, delta sync, retry backoff, and 60/120fps UI smoothness. |
| **Conflict Resolution Engine** | **Plugin Runtime** | Merges non-conflicting fields automatically; offers hooks for custom logic. |
| **Reactive UI Streams** | **Plugin Runtime** | Provides `watch()` streams with observable status flags (`synced`, `pending`, `conflict`). |

---

## 3. How `build_runner` Bridges the Gap

### Step 1: Developer defines a model (Dynamic)
```dart
@SyncEntity(endpoint: '/tasks')
class Task {
  @PrimaryKey()
  final String id; // UUIDv7
  final String title;
  final bool isCompleted;

  Task({required this.id, required this.title, required this.isCompleted});
}
```

### Step 2: Developer runs `dart run build_runner build`
The code generator creates `task.sync.g.dart`:
1. **SQLite Table Definition** with indices and sync metadata columns (`_sync_status`, `_version`, `_dirty_fields`).
2. **Type-Safe Repository** (`$TaskRepository`) with `save()`, `delete()`, `watchAll()`, `watchById()`.
3. **Mock Test Suite** (`MockTaskSyncTransport`) for instant offline testing.

### Step 3: Developer tests offline sync locally
```dart
void main() {
  test('saves task offline and queues outbox mutation', () async {
    final mockTransport = MockTaskSyncTransport();
    final client = await OfflinePlugin.test(transport: mockTransport);

    // Save offline
    await client.tasks.save(Task(id: 'uuid-1', title: 'Buy Milk', isCompleted: false));

    // Verify local DB has it with 'pending' status
    final task = await client.tasks.getById('uuid-1');
    expect(task.syncStatus, SyncStatus.pending);

    // Trigger mock sync
    await client.sync();
    expect(mockTransport.pushedMutations.length, 1);
  });
}
```

---

## 4. Why This Solves Your Confusion
- **The developer does NOT write sync logic.** They only declare their models and endpoints.
- **The plugin does NOT guess schemas.** `build_runner` generates the exact SQLite bindings and serialization at compile time.
- **Zero test friction:** Generated mock adapters let developers test offline mutations, retries, and conflicts with 100% deterministic unit tests.
