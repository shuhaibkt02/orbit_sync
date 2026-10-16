# 06: Schema Evolution & In-Flight Queued Mutation Upgrades (Challenge 8)

**What to build:**
A schema migration pipeline for in-flight outbox mutations queued across application updates:
1. Versioned outbox envelopes carrying `schema_version`.
2. Lazy upcasting migrators (`MutationMigrator`) transforming stored JSON payloads to current schema version before push.
3. Server version floor enforcement returning HTTP 426 Upgrade Required (`client_too_old`) for deprecated schemas, safely halting the queue without burning retry budgets.
4. Replay integrity: retried in-flight mutations retain original byte payloads to preserve idempotency hashes.

**Blocked by:**
- 05: Parent-Child DAG Dependencies & Selective Holding (Challenge 3)

**Status:** done

### Acceptance Criteria & Test Cases:
- [x] **Outbox Schema Versioning:** Table `_sync_outbox` includes `schema_version INTEGER NOT NULL DEFAULT 1`.
- [x] **Test Case 1 (Lazy Mutation Upcasting on Dequeue):**
  - Offline mutation saved on schema v1 (e.g. `{'name': 'John Doe'}`).
  - Client updates to schema v2 with migrator splitting `name` into `first_name` and `last_name`.
  - Worker dequeues and upcasts mutation to v2 before network transmission.
  - Server accepts v2 payload and marks mutation `synced`.
- [x] **Test Case 2 (Server Version Floor - HTTP 426 Upgrade Required):**
  - Server enforces minimum schema version floor (`min_schema_version = 2`).
  - Client attempts push with `schema_version: 1`.
  - Server rejects with HTTP 426 (`client_too_old`).
  - Worker enters `needsUpgrade` state and preserves pending mutation without burning retry count.
- [x] **Test Case 3 (Replay Integrity):**
  - Retrying an in-flight mutation re-sends the exact same payload to maintain deterministic idempotency hashing.

