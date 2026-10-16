# Phase 8: Unified Plugin Architecture & Profile Tiers

## 1. Core Principle: One Plugin for All
- It is **one single Flutter plugin**, not multiple fragmented packages.
- The **core engine is identical** for everyone:
  - Transactional SQLite Outbox (zero data loss).
  - Background Dart Isolate (smooth 60/120fps UI).
  - Reactive Flutter Streams (`watchAll`, `watchById`).
  - Automated test generation.

The developer simply chooses a profile mode (`basic`, `standard`, or `enterprise`) to control how deep the configurations and generated tests should be.

---

## 2. The Three Profile Tiers

```
SyncProfile
├── Basic (Low)        ──> 3-step setup, essential offline sync, basic test suite
├── Standard (Default)  ──> Field-level conflict resolution, network listeners, standard test suite
└── Enterprise (High)   ──> Multi-tenant, DAG cascade transactions, dead-letter queue, full chaos test suite
```

### Profile Breakdown:

| Feature / Capability | `SyncProfile.basic` (Low) | `SyncProfile.standard` (Default) | `SyncProfile.enterprise` (High) |
| :--- | :---: | :---: | :---: |
| **Setup Time** | 2 minutes | 5 minutes | 10 minutes |
| **Transactional Outbox** | ✅ Included | ✅ Included | ✅ Included |
| **Background Isolate (No Jank)** | ✅ Included | ✅ Included | ✅ Included |
| **Conflict Resolution** | Last-Write-Wins (LWW) | Field-Level Auto-Merge | Custom Domain Hooks + Audit Log |
| **Multi-Tenancy Isolation** | Single User | Single User | Multi-Tenant & Multi-User (`tenantId`) |
| **Background OS Schedulers** | App Foreground | App Foreground + Network Change | Full `WorkManager` & `BGTaskScheduler` |
| **Dead-Letter / Quarantine** | Simple Retry | Exponential Backoff | Dead-Letter Queue + Poison Pill Alert |

---

## 3. Automated Test Generation by Profile

`build_runner` reads the profile and generates the appropriate test suite:

### Tier 1: Basic (`basic`) - 3 Essential Tests
1. **Offline Write Test:** Verifies model saves offline immediately.
2. **Push Sync Test:** Verifies `200 OK` syncs to server.
3. **Network Retry Test:** Verifies failed calls remain in outbox.

### Tier 2: Standard (`standard`) - 5 Tests (Basic + Conflicts)
4. **Field-Level Conflict Test:** Verifies concurrent field merges deterministically.
5. **Tombstone Delete Test:** Verifies remote deletion deletes locally.

### Tier 3: Enterprise (`enterprise`) - 8+ Comprehensive & Chaos Tests
6. **Multi-Table Cascade Test:** Verifies parent + child DAG transactions commit atomically.
7. **Dead-Letter / Poison Pill Test:** Verifies malformed 422 errors move to dead-letter without blocking the queue.
8. **Multi-Tenant Leak Test:** Verifies Tenant A cannot see Tenant B's offline records.
9. **Simulated Crash Recovery Test:** Simulates app kill mid-sync and verifies no corrupt state.

---

## 4. How the Developer Configures It

### Option A: In the Model Annotation
```dart
@SyncEntity(
  endpoint: '/orders',
  profile: SyncProfile.enterprise, // or basic / standard
)
class Order { ... }
```

### Option B: In Initialization
```dart
final sync = await OfflineSync.init(
  baseUrl: 'https://api.example.com',
  profile: SyncProfile.standard, // One line switches the behavior
);
```

### Benefit:
- Beginners get maximum simplicity with zero boilerplate.
- Enterprises get full battle-tested guarantees and automated chaos tests.
- Everyone shares the exact same rock-solid core sync engine.
