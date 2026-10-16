# Changelog

All notable changes to the `offline_sync` package will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-10-16

### Added
- **Unified Developer Facade (`OfflineSyncClient`):**
  - One-line asynchronous initialization (`OfflineSyncClient.initialize(...)`).
  - Integrated CRUD helpers: `save()`, `delete()`, `query()`, and `watch()`.
  - Background lifecycle management: `startPeriodicSync()`, `pauseSync()`, `resumeSync()`, and `close()`.
  - Coordinated bidirectional sync: atomic outbox push followed by delta pull.
- **Storage Engine & Concurrency (`SyncStorage`):**
  - Powered by `sqlite_async` with a dedicated writer isolate and pooled reader isolates (WAL mode).
  - Universal RFC 4122 / draft UUIDv7 ID generator eliminating temporary ID rewrites.
  - Zero-codegen reactive queries via `db.watch(...)` on arbitrary runtime tables.
  - Transactional Outbox pattern (`_sync_outbox`) and shadow-base storage (`_shadow_base`) for optimistic local writes.
- **Resilient Sync Protocol & Worker (`SyncWorker`):**
  - Two Generals problem mitigation via client `Idempotency-Key` headers and deduplication.
  - Mid-sync crash recovery via transactional page-cursor checkpoints.
  - Non-blocking Poison Pill Dead-Letter Queue (`status: 'failed'`) with exponential backoff.
  - Parent-Child DAG dependency tracking: holds only dependent children if parent is quarantined, preventing head-of-line blocking for unrelated records.
  - Pragmatic 3-way column merge with RFC 9457 invariant validation error rollback.
  - Generation swap resync for expired cursors (HTTP 410 Gone).
  - Schema evolution migrators with lazy in-flight mutation upcasting on dequeue (v1 -> v2).
  - Server version floor enforcement on HTTP 426 (`client_too_old`) halting retries cleanly.
- **Unified Plugin Profiles (`SyncProfile`):**
  - Added `SyncProfile.basic` (LWW conflict resolution, simple retry, FIFO).
  - Added `SyncProfile.standard` (3-way column merge, exponential backoff, DLQ).
  - Added `SyncProfile.enterprise` (DAG selective holding, invariant validation, DLQ, multi-tenant).
- **Acceptance Test Suite:**
  - 29 comprehensive automated integration tests covering all distributed synchronization edge cases and profile tiers.
