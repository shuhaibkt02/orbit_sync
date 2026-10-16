# 02: sqlite_async Storage Engine & Transactional Outbox (Local Slice)

**What to build:**
A Dart client storage engine built on **`sqlite_async`** with WAL mode, dedicated writer isolate, and connection pooling. Implements atomic writes (`writeTransaction` with `BEGIN IMMEDIATE`) committing domain records and outbox mutation envelopes together, with reactive `db.watch()` streams.

**Blocked by:**
- 01: Fake In-Memory Test Server & Protocol Spec

**Status:** ready-for-agent

### Acceptance Criteria & Test Cases:
- [ ] **Engine Setup:** `SqliteDatabase` initialized with WAL mode, dedicated writer isolate, and pooled readers.
- [ ] **Outbox Schema:** Table `_sync_outbox` created with `mutation_id` (UUIDv7), `entity_name`, `entity_id`, `op`, `payload_json`, `base_version`, `status`, and `created_at`.
- [ ] **Test Case 1 (Single-Writer Concurrency - Challenge 1):** Concurrently reading via pooled readers while writing outbox mutations executes with zero `SQLITE_BUSY` errors.
- [ ] **Test Case 2 (Atomic Outbox Commit - Zero Data Loss):** Calling `save(entity)` writes to domain table and appends to outbox in one atomic transaction. Test asserts that if the outbox insert throws an exception, the domain table write is completely rolled back.
- [ ] **Test Case 3 (Shadow-Base Materialization):** Optimistic writes update table columns directly for fast SQL queries, while `_base_snapshot_json` stores the pre-mutation baseline for rollback.
- [ ] **Test Case 4 (Zero-Codegen Reactivity):** `db.watch('SELECT * FROM tasks;')` automatically streams updates on dynamic tables without requiring code-generated `TableInfo` classes.
