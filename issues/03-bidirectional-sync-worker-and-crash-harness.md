# 03: Bidirectional Client Sync Worker & Chaos Crash Harness

**What to build:**
A background sync worker connecting `sqlite_async` to the test server: drains outbox mutations to `POST /sync/push` with `Idempotency-Key` and pulls changelogs from `GET /sync/pull`. Includes a test harness verifying crash recovery, in-flight drops (Two Generals), and poison pill DLQ routing.

**Blocked by:**
- 02: sqlite_async Storage Engine & Transactional Outbox (Local Slice)

**Status:** ready-for-agent

### Acceptance Criteria & Test Cases:
- [ ] **Push & Pull Engine:** Sync worker drains outbox mutations and pulls paginated delta changes.
- [ ] **Test Case 1 (In-Flight Drop & Deduplication - Challenge 2):** Test server drops socket mid-push (`?chaos=drop_before_response`). Client reconnects and retries with same `Idempotency-Key`. Test asserts exactly 1 record exists on server and outbox mutation marks `synced`.
- [ ] **Test Case 2 (Checkpointed Pull & Mid-Sync SIGKILL - Challenge 4):** Server has 500 changes across 5 pages. Client pulls 2 pages and is terminated mid-sync with `SIGKILL`. Client restarts and resumes pull. Test asserts cursor resumes from page 2, 0 duplicates, and 0 missing rows.
- [ ] **Test Case 3 (Poison Pill DLQ & HoL Prevention - Challenge 8 & 9):** Queue has 1 malformed mutation (400 Bad Request) followed by 3 valid mutations. Test asserts malformed mutation routes to `dlq`, queue remains `running`, and the 3 valid mutations sync successfully.
- [ ] **Test Case 4 (Auth Refresh Pausing - Challenge 9):** Server returns 401 Unauthorized. Test asserts queue enters `refreshing` / `paused_offline` state, triggers token refresh, and does not burn the mutation retry budget.
- [ ] **Test Case 5 (Scope Eviction vs Tombstone - Challenge 5):** Client pulls `_deleted: true` -> deletes local row. Client pulls `left_scope: true` -> evicts local row without pushing a remote `DELETE`.
