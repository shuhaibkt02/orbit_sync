# 05: Parent-Child DAG Dependencies & Selective Holding (Challenge 3)

**What to build:**
Implementation and test harness for hierarchical parent-child entity synchronization:
1. Universal UUIDv7 identifiers eliminating client-side temporary ID rewrites.
2. Topological push ordering ensuring parent records commit before dependent children.
3. Selective holding: when a parent mutation is quarantined (DLQ or conflict), only its dependent child mutations are held (`status = 'held'`), while unrelated mutations in the queue continue syncing with zero Head-of-Line blocking.
4. Server-side foreign key constraint validation confirming orphaned children are rejected if selective holding is absent.

**Blocked by:**
- 04: Two-Client Conflict, Invariants & Convergence Test

**Status:** done

### Acceptance Criteria & Test Cases:
- [x] **Schema & Outbox Dependency Tracking:** Outbox schema includes `depends_on_mutation_id` for declaring DAG parent dependencies.
- [x] **Test Case 1 (Universal UUIDv7 & Local FK Integrity):** Parent `Order` and Child `OrderItem` created offline with UUIDv7 IDs. Local SQLite foreign key `order_id REFERENCES orders(id)` passes without temporary IDs or rewrites.
- [x] **Test Case 2 (Topological Push Ordering):** Sync worker pushes parent `Order` before child `OrderItem`. Server validates parent exists before inserting child; both mark `synced`.
- [x] **Test Case 3 (Selective Holding on Quarantined Parent):**
  - Parent `Order` triggers poison pill (HTTP 400) -> routes to `dlq`.
  - Dependent `OrderItem` is selectively `held` (preventing orphaned server FK rejection).
  - Unrelated `Task` pushes successfully (`status = 'synced'`).
- [x] **Test Case 4 (Parent Recovery Unblocks Held Children):**
  - When quarantined parent is corrected/re-queued (`status = 'pending'`) and syncs successfully, dependent `held` children are automatically unblocked and sync.

