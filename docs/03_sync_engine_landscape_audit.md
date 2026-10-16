# Phase 3: Sync Engine Landscape Audit & The 10-Point Flutter Gap

## 1. Executive Summary
A pure database (SQLite, Drift, Hive, Isar) is **not** a sync engine.
A simple HTTP retry interceptor (Dio retry, `offline_sync_outbox`) is **not** a sync engine.

A true enterprise sync engine must manage:
- Bidirectional delta sync (cursors, checkpoints, tombstones).
- Transactional outbox (atomic with business data).
- Conflict resolution (field-level merge, version vectors).
- Tenant isolation and migration-safe queued mutations.

---

## 2. Ecosystem Comparison

| Ecosystem | Maturity | Core Strengths | Central Weakness |
| :--- | :--- | :--- | :--- |
| **Flutter / Dart** | Fragmented | Strong local databases (Drift, SQLite); PowerSync has good SQLite sync. | **No universal sync kernel:** PowerSync couples to its proprietary backend; Brick lacks conflict resolution; small packages are only simple FIFO HTTP retries. |
| **JS / TypeScript** | Mature & Deep | WatermelonDB (clean sync protocol), Replicache (mutator rebase), RxDB (reactive plugins). | High web bias; complex setups. |
| **Python** | Server-Side Dominant | Strong transactional outbox (`django-jaiminho`), CDC (Debezium/Postgres WAL), Celery/Temporal. | Very few client-side mobile sync libraries. |

---

## 3. The 10-Point Blueprint for Our Flutter Plugin Kernel

Based on the audit, our plugin will bridge the exact 10 gaps missing in Flutter today:

1. **Pluggable Persistence Adapter:** Canonical SQLite (via Drift or `sqlite3` FFI) with interfaces for custom stores.
2. **Pluggable Transport Adapter:** Works with standard REST, GraphQL, gRPC, or WebSockets via a clean `SyncTransport` interface.
3. **Durable Transactional Outbox:** Business write and outbox entry committed together in a single SQLite transaction (zero data loss on crash).
4. **Built-in Idempotency:** Client-generated UUIDv7 keys, monotonic sequences, and replay-safe payload contracts.
5. **Bidirectional Delta Engine:** Cursor/checkpoint pulls, tombstone delete tracking, and selective sync scopes.
6. **Configurable Conflict Engine:** Default field-level merge, optimistic concurrency, and user-facing manual conflict hooks.
7. **Tenant & Multi-User Isolation:** Separate outbox, cursors, and encryption keys per tenant/user.
8. **Migration-Safe Queues:** Queued mutations survive schema upgrades via mutation versioning and quarantine/dead-letter rules.
9. **Operational Resilience:** Exponential backoff with jitter, circuit breaker, background scheduler integration (`WorkManager` / `BGTaskScheduler`).
10. **Reactive Sync-State UI:** Per-record observable states (`synced`, `pending`, `failed`, `conflict`, `stale`) for seamless Flutter UI binding.
