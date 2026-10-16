# Phase 6: Automated Test Case Generation via build_runner

## 1. The Core Question
**Can `build_runner` automatically generate test cases for a developer's dynamic models and APIs?**

**YES, 100%.** Dart's `build` and `source_gen` system can generate files in both `lib/` and `test/`. 

When a developer annotates their model with `@SyncEntity`, `build_runner` can automatically generate a full, ready-to-run offline sync test suite (`test/generated_<model>_sync_test.dart`).

---

## 2. What `build_runner` Inspects vs. What It Generates

```
Developer's Model (@SyncEntity)
├── Fields & Types (id, title, price, isCompleted)
├── Primary Key
└── REST/GraphQL Endpoint ('/api/v1/orders')
            │
            ▼ [ build_runner generates ]
test/order_offline_sync_test.dart
├── Test 1: Offline Local Write & Pending State
├── Test 2: Network Reconnect & Successful Push Sync
├── Test 3: Network Failure & Exponential Backoff
├── Test 4: Conflict Detection & Auto-Merge
└── Test 5: Remote Tombstone Deletion
```

---

## 3. The 5 Core Tests Auto-Generated for Every Model

Whenever a developer runs `dart run build_runner build`, the plugin generates an automated test file that tests their exact model:

1. **Offline Persistence Test:**
   - Creates a sample instance of the developer's model.
   - Simulates offline mode.
   - Saves to local SQLite.
   - Verifies the record exists immediately with status `SyncStatus.pending`.
2. **Push Sync & Outbox Drain Test:**
   - Simulates the network coming online.
   - Simulates server returning `200 OK`.
   - Verifies the outbox queue is cleared and the local record status switches to `SyncStatus.synced`.
3. **Resilience & Network Retry Test:**
   - Simulates network timeouts or HTTP 500 errors.
   - Verifies the mutation remains safely in the outbox.
   - Verifies retry count increments with exponential backoff (no data loss).
4. **Conflict Resolution Test:**
   - Simulates a concurrent update from the server for the same record.
   - Verifies field-level merge executes deterministically.
5. **Tombstone & Remote Deletion Test:**
   - Simulates server sending a delete delta (`_deleted: true`).
   - Verifies the record is correctly removed/evicted from the local SQLite database.

---

## 4. How the Developer Uses It

The developer only does two things:

```bash
# 1. Generate code and test cases
dart run build_runner build

# 2. Run the generated test suite
dart test test/generated_sync_tests/
```

### Result:
- Small apps and large enterprises get **instant, automated test verification** for their specific data models.
- Developers never have to manually mock SQLite or fake network disconnects.
