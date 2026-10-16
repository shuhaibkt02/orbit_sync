# Phase 17: Pragmatic Reboot & The Reality Audit

## 1. The Reality Check: What We Got Wrong
- **Theoretical theater is dead.** Special relativity, Rayleigh fading, and thermodynamics were distractions. A dropped connection is a socket timeout; it needs an idempotency header and exponential backoff, not physics equations.
- **Per-device sequence is NOT a Lamport clock.** It orders one device's writes; it tells us nothing about cross-device causal order.
- **Mode 1 ("zero backend changes") cannot guarantee zero data loss.** Standard REST `PUT` overwrites rows, and without server-side idempotency keys, network drops cause duplicate records.
- **Mode 2 is a sync server.** Tucking it into a 15-minute middleware checklist was delusional.
- **The 9-issue waterfall was a trap.** You couldn't save or sync a single row until Issue 10 and 13.
- **Drift vs direct FFI must be decided now.**

---

## 2. The Fixed Architectural Decisions

1. **Storage Engine:** **Drift** (`drift` + `drift_isolate`). 
   - We will NOT reinvent connection pools, stream query listeners, type mappers, migrations, and isolate IPC from scratch.
2. **Sync Protocol Contract:** A small, explicit REST specification:
   - Client-generated UUIDv4/UUIDv7 primary keys.
   - Header: `Idempotency-Key: <uuid>`.
   - Push: `POST /sync/push` (batch of mutations).
   - Pull: `GET /sync/pull?since=<cursor>` returning `{ changes: [...], next_cursor: "..." }`.
3. **Execution Phasing:** 
   - Build a **fake in-memory test server first**.
   - Build **one complete vertical slice**: write locally with outbox, push, pull, survive `kill -9`, and resolve a 2-client conflict.
   - Defer DAGs, generation swaps, AST codegen, and multi-tenant encryption until the core vertical slice is proven under real test chaos.

---

## 3. The 4 Pragmatic Issues (Replacing 01–13)

```
[Issue 01: Fake In-Memory Test Server & Protocol Spec]
   │
   ▼
[Issue 02: Drift Storage Engine & Transactional Outbox Slice]
   │
   ▼
[Issue 03: Bidirectional Sync Worker & SIGKILL Crash Harness]
   │
   ▼
[Issue 04: Two-Client Conflict & Convergence Test]
```
