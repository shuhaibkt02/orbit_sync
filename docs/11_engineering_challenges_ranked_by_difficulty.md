# Phase 11: Engineering Challenges Ranked by Difficulty (R&D & Mobile Systems Audit)

## Level 1: Extreme Difficulty (10/10) - Distributed Systems & Concurrency

### 1. Multi-Isolate SQLite Concurrency & Lock Contention (`SQLITE_BUSY`)
- **The Challenge:** Flutter runs UI on the Root Isolate. The sync engine writes in a Background Isolate. Simultaneously, native OS schedulers (`WorkManager` / `BGTaskScheduler`) might spawn a background execution. 
- **The Danger:** SQLite is a single-writer database. Concurrent writes or long transactions cause `SQLITE_BUSY` (database locked) crashes, freezing the UI.
- **R&D Solution:** Enforce SQLite **WAL (Write-Ahead Logging)** mode, shared connection pools via `drift_isolate` or serialized background ports, and strict busy-timeout handlers (e.g., 5000ms).

### 2. The In-Flight Network Drop (The Two Generals' Problem)
- **The Challenge:** The client pushes an outbox mutation. The server processes it and commits to its database. Before the `200 OK` reaches the device, the cellular connection drops.
- **The Danger:** The client assumes the request failed. When connection returns, it retries, potentially creating duplicate orders, double payments, or duplicate records.
- **R&D Solution:** Strict **UUIDv7-based idempotency keys** transmitted in headers (`X-Idempotency-Key: <uuid>`), plus monotonic client sequence numbers. The server must recognize duplicate keys and return cached responses without re-executing.

### 3. Parent-Child DAG Dependencies & Cascade Rewrites
- **The Challenge:** An offline user creates an `Invoice` (temporary ID `temp-1`) and 5 `InvoiceItems` (referencing `temp-1`).
- **The Danger:** If pushed out-of-order, the backend rejects items due to missing parent. If the backend assigns permanent server IDs, updating `temp-1` to `real-uuid` locally can trigger SQLite foreign key constraint violations.
- **R&D Solution:** A **Directed Acyclic Graph (DAG) queue** ensuring parents sync before children, wrapped in an atomic local transaction that temporarily disables or safely cascades foreign key rewrites.

---

## Level 2: High Difficulty (8–9/10) - Mobile Lifecycle & Data Semantics

### 4. iOS 30-Second Execution Cap & Checkpoint Resumability
- **The Challenge:** iOS `BGAppRefreshTask` permits only ~30 seconds of runtime. If an app exceeds this or uses too much memory, iOS terminates the process immediately.
- **The Danger:** App is killed mid-sync while pulling 5,000 records, corrupting the local sync state or leaving partial batches uncommitted.
- **R&D Solution:** **Pipelined Checkpointing.** Delta pulls must commit locally in small pages (e.g., 100 records per page). The sync cursor is saved per page, so if killed at second 28, the next wake-up resumes exactly where it stopped.

### 5. The "Tombstone vs. Scope Eviction" Trap
- **The Challenge:** Mobile apps sync a scoped subset of data (e.g., "Active Projects assigned to me").
- **The Danger:** If a project is closed on the server, it disappears from the user's sync query. A naive client might treat this as a deletion and push a `DELETE` request, erasing the record from the company server!
- **R&D Solution:** Strict separation between:
  - **Tombstones (`_deleted: true`):** True distributed deletion.
  - **Scope Eviction:** Local cache cleanup without broadcasting a remote delete.

### 6. Optimistic UI Rollback Without Data Regression
- **The Challenge:** When a user edits a task offline, the UI shows it instantly. If the server later permanently rejects the edit (e.g., HTTP 422: "Permission Denied"), the local state must rollback.
- **The Danger:** A naive rollback will overwrite newer edits the user made while waiting for sync.
- **R&D Solution:** Store base versions and local diffs. If rejected, rollback only the rejected patch or transition the entity to an explicit `SyncStatus.conflict` / `draft` state without destroying user input.

### 7. Dynamic AST Metaprogramming & Type Handling (Dart Analyzer)
- **The Challenge:** Flutter has no runtime reflection (`dart:mirrors` is disabled for AOT compilation). The code generator must parse any arbitrary user model via `analyzer` and `source_gen`.
- **The Danger:** Generics, nested custom classes, nullable enums, and complex `DateTime` formats can cause generator crashes or generate uncompilable code.
- **R&D Solution:** A disciplined type-visitor architecture with strict schema validators and fallbacks to JSON-serializable primitives.

---

## Level 3: Moderate-to-High Difficulty (6–7/10) - Operations & Resilience

### 8. Schema Evolution & In-Flight Queued Mutation Upgrades
- **The Challenge:** A user creates an offline mutation on v1.0 of the app. The app is updated from the App Store to v2.0 (with a modified table schema) while mutations are still queued.
- **R&D Solution:** Versioned mutation envelopes (`schema_version: 2`). Migrators run on pending outbox payloads before execution.

### 9. Poison Pills & Head-of-Line Blocking (Dead-Letter Queue)
- **The Challenge:** A single malformed mutation (e.g., HTTP 400 Bad Request) fails every retry.
- **The Danger:** A strict FIFO queue will get permanently blocked, preventing subsequent valid mutations from ever syncing.
- **R&D Solution:** Error classification. 4xx business validation errors are immediately quarantined into a **Dead-Letter Queue (DLQ)** with user alerts, allowing the rest of the queue to continue.

### 10. Automated Mock & Chaos Test Generation
- **The Challenge:** Generating reliable, zero-flakiness unit test suites for dynamic developer models that run with `dart test`.
- **R&D Solution:** Pre-built test harnesses that inject in-memory SQLite databases and programmatic HTTP mock adapters.
