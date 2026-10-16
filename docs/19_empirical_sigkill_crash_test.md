# Phase 19: Empirical SIGKILL Crash Recovery Benchmark Results

**Environment:** Dart 3.13.0 | sqlite3 3.51.0 (package:sqlite3 2.9.4) | macOS arm64  
**Harness:** `.scratch/spikes/dart_wal_spike/bin/kill_test.dart` and `bin/writer_process.dart`  
**Execution:** Child OS process executing tight `BEGIN IMMEDIATE` 50-row insert transactions, killed mid-flight with `ProcessSignal.sigkill` (`exitCode = -9`).

---

## 1. Raw Execution Log

```text
=== SQLite WAL SIGKILL Crash Harness ===
Dart 3.13.0 | sqlite3 Version(libVersion: 3.51.0) | macos

--- Cycle 1: Spawning writer, waiting for active writes, then killing with SIGKILL ---
  Killed with SIGKILL (true), exitCode=-9, last ACKed txn: 941
  [PASS] Integrity: ok | Max Txn in DB: 941 (>= 941) | Total Rows: 47050 (multiple of 50) | Partial txns: 0

--- Cycle 2: Spawning writer, waiting for active writes, then killing with SIGKILL ---
  Killed with SIGKILL (true), exitCode=-9, last ACKed txn: 1478
  [PASS] Integrity: ok | Max Txn in DB: 1479 (>= 1478) | Total Rows: 73950 (multiple of 50) | Partial txns: 0

--- Cycle 3: Spawning writer, waiting for active writes, then killing with SIGKILL ---
  Killed with SIGKILL (true), exitCode=-9, last ACKed txn: 2387
  [PASS] Integrity: ok | Max Txn in DB: 2387 (>= 2387) | Total Rows: 119350 (multiple of 50) | Partial txns: 0

--- Cycle 4: Spawning writer, waiting for active writes, then killing with SIGKILL ---
  Killed with SIGKILL (true), exitCode=-9, last ACKed txn: 2806
  [PASS] Integrity: ok | Max Txn in DB: 2806 (>= 2806) | Total Rows: 140300 (multiple of 50) | Partial txns: 0

--- Cycle 5: Spawning writer, waiting for active writes, then killing with SIGKILL ---
  Killed with SIGKILL (true), exitCode=-9, last ACKed txn: 3400
  [PASS] Integrity: ok | Max Txn in DB: 3401 (>= 3400) | Total Rows: 170050 (multiple of 50) | Partial txns: 0

=== ALL 5 KILL-AND-RECOVER CYCLES PASSED WITH ZERO CORRUPTION ===
```

---

## 2. Hard Invariants Proven
1. **Zero Process-Kill Corruption:** `PRAGMA integrity_check` returned `ok` across all 5 consecutive crash-and-recover cycles on the same database file reaching 170,050 rows.
2. **Zero Acknowledged Data Loss:** Every transaction acknowledged to stdout was present upon reopening the database (`Max Txn in DB >= last ACKed txn`).
3. **Zero Partial Transactions:** In all 5 cycles, every single `txn_id` in the database contained **exactly 50 rows**. The uncommitted transaction in-flight at the moment `SIGKILL` struck was cleanly rolled back by SQLite WAL recovery.
