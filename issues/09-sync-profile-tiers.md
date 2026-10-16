# 09: SyncProfile Tiers (Basic, Standard, Enterprise)

**What to build:**
Implement the three profile tiers specified in `docs/08_unified_plugin_profiles_and_test_tiers.md`:
1. `enum SyncProfile { basic, standard, enterprise }`.
2. Configure `OfflineSyncClient.initialize(profile: ...)` to apply profile presets.
3. Wire profile tier behaviors into `SyncWorker`:
   - `SyncProfile.basic`: Last-Write-Wins (LWW) conflict resolution, simple retry on poison pills, FIFO push.
   - `SyncProfile.standard`: 3-way column merge, exponential backoff, DLQ poison pill isolation.
   - `SyncProfile.enterprise`: Full distributed guarantees with Parent-Child DAG selective holding, RFC 9457 invariant validation, and DLQ.
4. Comprehensive automated tests in `test/profile_tiers_test.dart` verifying all 3 profiles.

**Blocked by:**
- 08: Package Documentation, License, Changelog, and Example Flutter App

**Status:** done

### Acceptance Criteria & Test Cases:
- [x] **Test Case 1 (SyncProfile.basic):** Verifies that `basic` uses Last-Write-Wins (LWW) where remote changes overwrite conflicting local rows, and marks outbox as conflict.
- [x] **Test Case 2 (SyncProfile.standard):** Verifies that `standard` applies field-level 3-way auto merge and isolates poison pills into DLQ.
- [x] **Test Case 3 (SyncProfile.enterprise):** Verifies that `enterprise` enforces Parent-Child DAG selective holding and invariant validation rollback.
