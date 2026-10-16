# 07: Unified Developer Client Facade (OfflineSyncClient)

**What to build:**
A high-level DX client facade (`OfflineSyncClient`) unifying storage, sync worker, periodic polling, pause/resume lifecycle controls, and reactive streams:
1. One-line initialization (`OfflineSyncClient.initialize(...)`).
2. Unified CRUD API: `save()`, `delete()`, `query()`, `watch()`.
3. Background lifecycle controls: `startPeriodicSync()`, `pauseSync()`, `resumeSync()`.
4. Coordinated bidirectional sync: `sync()` drains outbox push, then executes delta pull.

**Blocked by:**
- 06: Schema Evolution & In-Flight Queued Mutation Upgrades (Challenge 8)

**Status:** done

### Acceptance Criteria & Test Cases:
- [x] **One-line Initialization:** `OfflineSyncClient.initialize()` creates storage, system schemas, and sync worker.
- [x] **Test Case 1 (Integrated CRUD & Reactivity):** Saving and deleting records updates local tables, appends outbox envelopes, and fires reactive `client.watch()` stream emissions.
- [x] **Test Case 2 (Coordinated Bidirectional Sync):** Calling `client.sync()` drains local outbox mutations to the server, then pulls incoming remote changes.
- [x] **Test Case 3 (Periodic Sync & Lifecycle Pause/Resume):** Client runs automatic periodic background sync. `pauseSync()` halts periodic execution; `resumeSync()` unpauses it.
- [x] **Test Case 4 (Clean Shutdown):** `client.close()` shuts down active background timers, cancels connections, and frees database resources cleanly.

