# ⏱️ SLA Monitor: Production Architecture Blueprint & Hardened Specification

> **Status:** Approved Architectural Blueprint (Deferred for next schema upgrade milestone)  
> **Target Subsystem:** `packages/offline_sync/lib/src/observability/services/sla_monitor.dart` & `packages/offline_sync/lib/src/storage/`  
> **Key References:** [01_STORAGE_LAYER.md](file:///Users/shuhaibkt/development/dev/work/offline_plugin/docs/layers/01_STORAGE_LAYER.md), [06_OBSERVABILITY_TELEMETRY_LAYER.md](file:///Users/shuhaibkt/development/dev/work/offline_plugin/docs/layers/06_OBSERVABILITY_TELEMETRY_LAYER.md)

---

## 1. Executive Summary & Problem Formulation

In offline-first enterprise applications, mutations queued offline often have contractual or operational Service Level Agreements (SLAs)—e.g., *"Medical dosage logs must sync within 15 minutes"*, *"Warehouse pick orders must sync within 2 hours"*.

The SLA Monitor detects two critical thresholds:
1. **Early Warning ($\ge 80\%$ of SLA duration):** Proactive alert so users can move to Wi-Fi.
2. **Breach ($\ge 100\%$ of SLA duration):** Critical operational breach notification.

### The Pitfalls of Naive Implementations:
1. **WAL Contention & Battery Drain:** Continuous sub-second polling prevents CPU sleep states, drains mobile batteries, and stalls WAL checkpoints if read transactions overlap with high-throughput writes.
2. **Expression Index Mismatches:** SQLite cannot use an index on `(created_at + sla_seconds * 1000)` if queries attempt arithmetic variations (such as `* 800`).
3. **Multi-Session Alert Storms:** Pure in-memory deduplication sets (`_warned`, `_breached`) reset on app restart, spamming duplicate breach banners every time the app launches.
4. **Multi-Isolate Race Conditions:** If background schedulers (e.g., WorkManager) and the UI isolate concurrently update alert state, non-atomic writes can cause state regression.
5. **OS Suspension Realities:** Dart timers are frozen when iOS or Android suspends an app in the background.

---

## 2. Hardened Schema & Insertion Model

To guarantee instant, indexed integer comparisons without runtime arithmetic in SQL, calculate exact epoch timestamps upfront during `save()` insertion:

### Schema Additions
```sql
ALTER TABLE _sync_outbox ADD COLUMN sla_alert_level INTEGER NOT NULL DEFAULT 0;
ALTER TABLE _sync_outbox ADD COLUMN sla_warn_at INTEGER;
ALTER TABLE _sync_outbox ADD COLUMN sla_deadline_at INTEGER;
```

### Pre-computation on Insert (`save()`)
```dart
final int nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
final int? slaSeconds = sla?.inSeconds;

final int? slaWarnAt = slaSeconds != null && slaSeconds > 0
    ? nowMs + (slaSeconds * 800) // 80% early warning threshold
    : null;

final int? slaDeadlineAt = slaSeconds != null && slaSeconds > 0
    ? nowMs + (slaSeconds * 1000) // 100% hard deadline
    : null;
```

### Index Strategy: Partial Index vs. Status Filter
* **Reality Check:** Active outbox size in typical apps is small ($< 1,000$ rows). A table scan on active rows takes $< 1\text{ms}$.
* **If an index is used:** It **must strictly mirror the query's partial index terms** and keep `sla_warn_at` as the leading column (avoiding range filters on leading columns):
```sql
CREATE INDEX IF NOT EXISTS idx_sync_outbox_active_sla 
ON _sync_outbox(sla_warn_at) 
WHERE status IN ('pending', 'in_flight', 'failed', 'held') 
  AND sla_alert_level < 2;
```

---

## 3. The "Zero Alert Storm" Migration Backfill

When rolling out this schema update to existing devices with pre-existing queued mutations, a three-band backfill prevents an immediate barrage of stale warnings and breach alerts on boot:

```sql
-- Step 1: Precompute timestamps for legacy rows
UPDATE _sync_outbox 
SET sla_warn_at = created_at + (sla_seconds * 800),
    sla_deadline_at = created_at + (sla_seconds * 1000)
WHERE sla_seconds IS NOT NULL 
  AND sla_seconds > 0 
  AND sla_deadline_at IS NULL;

-- Step 2: 3-Band Level Assignment for active records (avoiding alert storms)
UPDATE _sync_outbox
SET sla_alert_level = CASE 
    WHEN sla_deadline_at <= ? THEN 2 -- Already breached: silence both warn & breach
    WHEN sla_warn_at <= ?     THEN 1 -- In warning band: silence warning, await breach
    ELSE 0                           -- Unalerted: normal lifecycle
END
WHERE status IN ('pending', 'in_flight', 'failed', 'held') 
  AND sla_deadline_at IS NOT NULL;

-- Step 3: Permanently silence historical terminal records (synced, dlq, cancelled)
UPDATE _sync_outbox 
SET sla_alert_level = 2 
WHERE status NOT IN ('pending', 'in_flight', 'failed', 'held');
```
*(Passing the migration execution UTC epoch timestamp `?`)*.

---

## 4. The Active Evaluation Query

The query explicitly includes the partial index terms and active status filter so completed/pruned records never match:

```sql
SELECT mutation_id, entity_name, entity_id, created_at, sla_seconds, 
       sla_alert_level, sla_warn_at, sla_deadline_at
FROM _sync_outbox
WHERE status IN ('pending', 'in_flight', 'failed', 'held')
  AND sla_alert_level < 2
  AND sla_warn_at IS NOT NULL
  AND sla_warn_at <= ?
```

---

## 5. Dart State Machine & Multi-Isolate Monotonic Writes

### 1. In-Memory Transition Logic (Single Alert on Long Suspend)
If an app was suspended for 4 hours and resumes past deadline, emit **only** the breach alert (do not fire both warning and breach back-to-back):

```dart
int? targetLevel;
SyncEvent? eventToEmit;

if (nowMs >= deadlineAt) {
  // Jump straight to level 2, suppressing redundant warning
  targetLevel = 2;
  eventToEmit = SlaBreachedEvent(
    timestamp: DateTime.fromMillisecondsSinceEpoch(nowMs, isUtc: true),
    mutationId: id,
    entity: entity,
    entityId: entityId,
    age: Duration(milliseconds: nowMs - createdAt),
    sla: Duration(seconds: slaSeconds),
  );
} else if (currentLevel == 0 && nowMs >= warnAt) {
  targetLevel = 1;
  eventToEmit = SlaWarningEvent(
    timestamp: DateTime.fromMillisecondsSinceEpoch(nowMs, isUtc: true),
    mutationId: id,
    entity: entity,
    entityId: entityId,
    age: Duration(milliseconds: nowMs - createdAt),
    sla: Duration(seconds: slaSeconds),
  );
}
```

### 2. At-Least-Once Delivery & Monotonic SQL Write
To ensure alerts are never lost across sudden crashes:
1. Emit `eventToEmit` to the broadcast stream first.
2. Persist the updated alert level using a **monotonic write** guard:
```sql
UPDATE _sync_outbox 
SET sla_alert_level = ? 
WHERE mutation_id = ? 
  AND sla_alert_level < ?
```
*Why this matters:* If a background isolate (e.g. headless WorkManager sync) runs concurrently with the UI isolate, `AND sla_alert_level < ?` guarantees state **never regresses backward** (e.g., from 2 back to 1).

### 3. Terminal State Cleanup
When any mutation succeeds (`synced`) or is quarantined (`dlq` / `cancelled`), set `sla_alert_level = 2` within that exact transaction to permanently silence it:
```sql
UPDATE _sync_outbox 
SET status = 'synced', sla_alert_level = 2, next_retry_at = NULL 
WHERE mutation_id = ?
```

### 4. Lifecycle Invariant: Retries Never Reset the Clock
Manual retries (`retryMutation` / `retryAllFailed`) reset `status = 'pending'` and `retry_count = 0`, but **never reset `sla_alert_level` or `created_at`**. The SLA belongs to the original mutation, not the retry attempt.

---

## 6. Mobile Platform Boundaries

| Mode | Behavior | Mechanism |
| :--- | :--- | :--- |
| **Foreground (Active UI)** | Real-time SLA monitoring every 30s | Dart `Timer.periodic` |
| **Background (Locked / Pocket)** | **Dart timer suspended** by OS | iOS Suspend / Android Doze |
| **Resume (App Re-opened)** | Instant evaluation on resume | `notifyAppResumed()` triggers immediate SLA check |
| **True Background Push/Alarms** | Out of scope for pure Dart plugin | Requires host app native integration (WorkManager / AlarmManager) |

> [!IMPORTANT]
> Orbit's SLA Monitor is strictly an **in-process, foreground telemetry engine**. It powers in-app banners, warning badges, and diagnostics. If a business demands device notification alerts while the app is killed in the user's pocket, the host app must register OS-level alarms (`onScheduleNativeAlarm`).

---

## 7. Implementation Checklist for Future Sprint

- [ ] Add `sla_alert_level`, `sla_warn_at`, and `sla_deadline_at` columns to `_sync_outbox` schema.
- [ ] Implement the 3-band backfill in `SqliteSchema.initSystemSchema()`.
- [ ] Precompute `sla_warn_at` and `sla_deadline_at` in `SqliteOutboxWriter.save()`.
- [ ] Update `SlaMonitor.evaluate()` to use the partial index query and monotonic writes.
- [ ] Add test suite verifying:
  - 3-band migration does not fire alert storms on legacy rows.
  - Multi-isolate monotonic writes prevent alert level regression.
  - At-least-once delivery retains alerts across process restarts.
  - Terminal mutations (`synced`, `dlq`) set level 2 and never alert.
