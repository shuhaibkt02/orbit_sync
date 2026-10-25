# 📊 Layer 6: Observability & Telemetry Layer (`SyncObserver`)

> **Location:** `packages/offline_sync/lib/src/sync_observer.dart` & `sync_logger.dart`  
> **Key Collaborators:** All system layers (`OfflineSyncClient`, `SyncWorker`, `SyncStorage`, `ConnectivityMonitor`)  
> **Primary Responsibility:** Eliminating the "black box", emitting typed lifecycle event streams, monitoring SLAs, and providing manual retry controls.

---

## 1. Architectural Role & Responsibilities

Because an offline sync engine operates in the background, if anything fails silently, the developer and business lose trust in the product. The Observability & Telemetry Layer ensures that **every state transition, network error, merge conflict, and SLA breach is broadcasted transparently**.

### Single Responsibilities:
1. **Zero-Hiding Transparency:** Emit real-time, unfiltered diagnostics so developers always know what is happening under the hood.
2. **Comprehensive Trigger Broadcasting:** Collect and emit events across all 5 operational sources (Connectivity, Storage, SLA, Consensus, Transport).
3. **SLA Monitoring & Early Warning:** Calculate time elapsed and emit warnings when business sync deadlines are approaching.
4. **Log Bloat Protection:** Use in-memory circular buffers to prevent writing massive log files to phone storage in production.
5. **Manual Overrides:** Provide programmatic APIs for developers to trigger manual retries on quarantined records.

---

## 2. Comprehensive Observer Trigger Map

Events are emitted from every layer in the system:

```text
┌────────────────────────────────────────────────────────────────────────┐
│                       OBSERVER EVENT TRIGGERS                          │
├─────────────────┬──────────────────────────────────────────────────────┤
│ 1. Connectivity │ • onOnline: Internet signal restored                 │
│    Trigger      │ • onOffline: Signal lost                             │
│                 │ • onProbeTimeout: Captive portal or fake Wi-Fi       │
├─────────────────┼──────────────────────────────────────────────────────┤
│ 2. Storage      │ • onMutationQueued: Record saved locally (0ms)       │
│    Trigger      │ • onMutationCoalesced: Repeated edits squashed       │
│                 │ • onDatabasePruned: Old synced audit records cleared │
│                 │ • onStorageWarning: Device disk space critically low │
├─────────────────┼──────────────────────────────────────────────────────┤
│ 3. SLA Monitor  │ • onSlaWarning: 80% of allowed sync duration elapsed │
│    (Heartbeat)  │ • onSlaBreached: Strict business deadline expired!   │
├─────────────────┼──────────────────────────────────────────────────────┤
│ 4. Consensus &  │ • onConflictDetected: 3-way merge outcome            │
│    Engine       │ • onPoisonPillQuarantined: Record moved to DLQ       │
│                 │ • onCascadeFailure: Dependent children held in DLQ   │
│                 │ • onSyncRejected: Server rejected business invariant │
├─────────────────┼──────────────────────────────────────────────────────┤
│ 5. Transport    │ • onRateLimited: HTTP 429 Retry-After active         │
│    Trigger      │ • onAuthExpired: HTTP 401 token refresh triggered    │
└─────────────────┴──────────────────────────────────────────────────────┘
```

---

## 3. Developer Integration in Practice

Developers easily subscribe to typed streams and pipe data to Firebase, Sentry, or custom UI banners:

```dart
// 1. SLA Breach Alert: Show in-app banner to user
orbit.onSlaBreached.listen((item) {
  notificationService.showWarning(
    'Order #${item.entityId} is overdue! Please connect to Wi-Fi to sync.',
  );
});

// 2. Server Rejection Event: Show business conflict dialog
orbit.onSyncRejected.listen((rejection) {
  dialogService.showError(
    'Unable to reserve ${rejection.entityId}: ${rejection.errorMessage}',
  );
});

// 3. Low Storage Warning: Prevent abrupt crashes
orbit.onStorageWarning.listen((warning) {
  dialogService.showWarning(
    'Your device storage is almost full. Please free up space to continue syncing.',
  );
});

// 4. Manual Retry APIs (1-Tap Overrides)
await orbit.retryMutation('mut-102'); // Retry specific quarantined item
await orbit.retryAllFailed();         // Flush all recoverable failures
```

---

## 4. Deep-Dive Production Challenges & Architectural Defenses

### Challenge 1: Log File Bloat on User Devices
* **The Failure:** Writing verbose logs for every SQLite operation fills up user phone storage with log files over time.
* **The Defense: In-Memory Circular Buffers**:
  * In production, the logger defaults to `LogLevel.warn`.
  * Keeps an **In-Memory Circular Buffer of the last 100 events** (`Queue<SyncEvent>`).
  * If a critical error occurs, the developer can dump the last 100 in-memory events to Sentry or an error report without constantly writing to disk.

### Challenge 2: Accidental Spamming of System Notifications
* **The Failure:** If the plugin tries to show system push notifications directly for SLA breaches, it requires complicated OS notification permissions, native Android channels, and iOS authorizations that crash if misconfigured.
* **The Defense: Pure Event Streaming**:
  * Orbit **never attempts to display native OS notifications directly**.
  * It emits pure Dart events (`onSlaBreached`, `onStorageWarning`).
  * The host app decides whether to show an in-app banner, a toast, or a native notification using its existing notification system.

### Challenge 3: Hardened Multi-Session SLA Deduplication & Zero-Storm Backfill
* **The Blueprint:** See [SLA_MONITOR_PRODUCTION_BLUEPRINT.md](../SLA_MONITOR_PRODUCTION_BLUEPRINT.md) for the complete specification on precomputed timestamps (`sla_warn_at`, `sla_deadline_at`), 3-band migration backfill, monotonic multi-isolate writes (`sla_alert_level < ?`), and mobile OS sleep/suspend platform boundaries.
