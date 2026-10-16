# 04: Two-Client Conflict, Invariants & Convergence Test

**What to build:**
A multi-client simulation test running two distinct `sqlite_async` client instances against the test server. Verifies deterministic conflict resolution, rollback of rejected mutations, and enforcement of co-dependent invariant validators.

**Blocked by:**
- 03: Bidirectional Client Sync Worker & Chaos Crash Harness

**Status:** ready-for-agent

### Acceptance Criteria & Test Cases:
- [ ] **Multi-Client Setup:** Two independent database files (`client_a.db`, `client_b.db`) synced to the same test server.
- [ ] **Test Case 1 (Non-Conflicting Field Merge):**
  - Both clients go offline.
  - Client A updates `title: 'Updated by A'`.
  - Client B updates `priority: 'high'`.
  - Both clients sync. Test asserts both converge to `Task(title: 'Updated by A', priority: 'high')`.
- [ ] **Test Case 2 (Co-Dependent Invariant Violation - Challenge 7):**
  - Model has invariant: `start_time < end_time`.
  - Client A offline sets `start_time = 18:00`. Client B offline sets `end_time = 12:00`.
  - Both sync. Test asserts `validateInvariants` fails, auto-merge is rejected, and record enters `SyncStatus.conflict` with RFC 9457 details preserved.
- [ ] **Test Case 3 (Optimistic Rollback on Server 422 - Challenge 6):**
  - Client updates record offline. Server rejects with HTTP 422.
  - Test asserts local state rolls back to `_base_snapshot_json`, while the user's rejected edit is kept as an observable `draft`.
- [ ] **Test Case 4 (Generation-Swap Resync on 410 Gone - Challenge 5 & 9):**
  - Server returns HTTP 410 Gone for an expired cursor.
  - Test asserts client pulls into staging tables, swaps active tables atomically, and preserves pending outbox mutations.
