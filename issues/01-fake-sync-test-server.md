# 01: Fake In-Memory Test Server & Protocol Spec

**What to build:**
A minimal standalone test server (Python or Node) implementing the explicit sync contract with chaos injection, serving as the test backend for all client sync test cases.

**Blocked by:** None (can start immediately)

**Status:** done

### Acceptance Criteria & Test Cases:
- [x] **Contract Endpoints:**
  - `POST /sync/push`: accepts mutation batch with `Idempotency-Key` header and monotonic sequence number.
  - `GET /sync/pull?since=<cursor>&limit=<n>`: returns `{ changes: [...], next_cursor: "...", has_more: bool }`.
- [x] **Test Case 1 (Idempotent Deduplication - Challenge 2):** Retrying `POST /sync/push` with the same `Idempotency-Key` returns the cached response without creating duplicate records.
- [x] **Test Case 2 (Monotonic Change Feed - Challenge 4):** Changes are ordered by monotonic commit sequence, and pull pagination cleanly splits at page limits without skipping records.
- [x] **Test Case 3 (Tombstone vs Scope Eviction - Challenge 5):** Emits `_deleted: true` for global deletes and `left_scope: true` for records leaving the client's sync filter.
- [x] **Test Case 4 (Chaos Injection):** Supports query flags:
  - `?chaos=drop_before_response`: commits to DB then abruptly closes TCP socket (Two Generals' test).
  - `?chaos=conflict`: returns HTTP 409 Conflict with current server version.
  - `?chaos=validation_error`: returns HTTP 422 with RFC 9457 field errors.
  - `?chaos=expired_cursor`: returns HTTP 410 Gone when cursor is past retention window.

