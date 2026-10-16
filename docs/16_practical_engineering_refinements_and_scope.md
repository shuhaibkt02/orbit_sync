# Phase 16: Practical Engineering Refinements & Scope Discipline

## 1. Executive Summary
This document incorporates the Staff/Principal Engineer critique to bridge the gap between academic theory and pragmatic mobile production execution.

We fix the 4 practical implementation traps and resolve the "Zero-Backend" contradiction by strictly phasing our milestones.

---

## 2. Resolving the "Zero-Backend" Contradiction: Two-Mode Transport

We decouple the client engine from backend assumptions by supporting two distinct transport adapters:

### Mode 1: `RestCrudAdapter` (Best-Effort / Legacy Backend Mode)
- **Target:** Existing standard REST/GraphQL APIs (Node/Express, Django, Laravel, Rails) with **zero backend changes**.
- **Mechanics:**
  - Standard HTTP endpoints (`POST /items`, `PUT /items/:id`, `DELETE /items/:id`, `GET /items`).
  - Outbox gives transactional local writes, DAG ordering, and background retry loops.
  - Delivery is **at-least-once** with client-side UUIDs or server ID re-mapping.
  - Pull sync operates via timestamp/ETag polling or simple collection refresh.
- **Guarantee:** Best-effort offline-first for standard CRUD without requiring backend rewrites.

### Mode 2: `DeltaSyncProtocolAdapter` (Lossless / Enterprise Contract Mode)
- **Target:** Production enterprise backends requiring guaranteed zero data loss.
- **Mechanics:**
  - Full implementation of Doc 12: `(device_id, install_epoch, seq)`, monotonic `commit_seq` changelog, tombstones, `left_scope`, and `HTTP 410 Gone` generation swaps.
  - Shipped with **drop-in reference server middleware** (FastAPI, Express, Go) that developers can mount in 15 minutes.

---

## 3. The 4 Critical Engineering Refinements

### Refinement A: Shadow-Base Materialization (Fixes SQL Query Performance)
- **Problem:** Computing UI state on the fly via `foldl` across JSON outbox patches destroys SQLite index speed and prevents native `WHERE` and `ORDER BY` queries.
- **Solution:** 
  - Materialize optimistic writes **directly into the main SQLite table columns** so native SQL queries run at full C speed.
  - Store unmutated server snapshots in a `_base_snapshot_json` column *only* for records with active pending mutations (`_sync_status != 'synced'`).
  - On 422 rejection or 409 rebase, restore `_base_snapshot_json` and re-apply remaining pending mutations for that single record only.

### Refinement B: Debounced Coalesced Isolate Invalidation (Fixes UI Frame Drops)
- **Problem:** Pulling 5,000 records in pages of 100 fires 50 cross-isolate invalidations in 3 seconds, causing the UI isolate to re-run `SELECT *` 50 times and freeze Flutter animations.
- **Solution:** 
  - The background sync isolate coalesces table changes and emits invalidation pulses throttled to **250ms–500ms** during active bulk pulls.
  - UI queries re-trigger only on debounced batch boundaries.

### Refinement C: Atomic Conflict Groups & Invariant Validators (Fixes Co-Dependent Fields)
- **Problem:** Blind field-level auto-merge creates impossible domain states (e.g. `start_time > end_time` or `spent > budget`).
- **Solution:**
  - Models support a `bool validateInvariants(T merged)` hook.
  - If a merged record violates the domain invariant, auto-merge refuses to commit and drops the record into `SyncStatus.conflict` for user/business review.

### Refinement D: Lightweight CLI Test Generator (Avoids `build_runner` Test Directory Wars)
- **Problem:** Dart's `build` package strictly forbids builders in `lib/` from writing output files into `test/` without complex, fragile `build.yaml` configurations.
- **Solution:**
  - `offline_sync_generator` generates mock harnesses and helper classes inside `lib/src/generated/`.
  - A simple, fast CLI tool (`dart run offline_sync init-tests`) creates the test suite in `test/` directly without fighting `build_runner` constraints.

---

## 4. Ruthless Milestone Discipline (Phased Roadmap)

```
[Phase 1: V0.1 Engine Kernel] (Runtime Registration Mode)
├── 1. SQLite WAL + BEGIN IMMEDIATE + Transactional Outbox
├── 2. RestCrudAdapter (Dumb REST) + DeltaSyncProtocolAdapter (Full Protocol)
├── 3. Dual DFA State Machine (Queue vs Mutation)
└── 4. Background Isolate Worker with Debounced Stream Invalidation
        │
[Phase 2: V0.2 Advanced Semantics]
├── 5. DAG Selective Holding + Shadow-Base Materialization
├── 6. Invariant Validators & Generation-Swap Full Resync (410)
└── 7. Reference Server Middleware (FastAPI / Express)
        │
[Phase 3: V0.3 Codegen & Tooling]
├── 8. @SyncEntity AST Code Generator (build_runner)
└── 9. CLI Test Suite Generator (dart run offline_sync init-tests)
```
