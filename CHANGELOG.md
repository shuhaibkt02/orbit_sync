# Changelog

All notable changes to the `orbit_sync` package will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-10-25

### Added
- **Production Clean Architecture Release (Layers 1-6):**
  - **Layer 1: Storage Layer (`SyncStorage`):**
    - Transactional Outbox pattern with atomic SQLite WAL writes.
    - Single dedicated writer isolate with pooled concurrent reader isolates.
    - Monotonic RFC 9562 UUIDv7 ID generator.
    - Dynamic runtime table registration, soft-delete undo windows, and TTL cache pruning.
  - **Layer 2: Consensus Engine (`SyncWorker`):**
    - Two Generals mitigation via client-generated `Idempotency-Key` headers.
    - Parent-child DAG dependency resolution preventing head-of-line blocking.
    - Monotonic capped exponential backoff with randomized full jitter.
    - Pragmatic 3-way column merge with RFC 9457 invariant validation rollbacks.
    - Non-blocking Dead-Letter Queue (DLQ) quarantining.
  - **Layer 3: Connectivity Layer (`ConnectivityMonitor`):**
    - Asymmetric Flap Guard (3-second reconnect debounce, 0ms immediate disconnect).
    - Captive portal and walled-garden detection via HTTP canary probes.
    - Metered network synchronization policies (`any`, `wifiOnlyMedia`, `wifiOnlyAll`).
    - Instant app resume wakeup (`notifyAppResumed`) and deterministic offline testing (`simulateOffline`).
  - **Layer 4: Transport Layer (`SyncTransport`):**
    - Zero metadata pollution: outbox metadata kept strictly in HTTP headers, keeping JSON payloads pure.
    - Split timeout anatomy (3s connect timeout, 10s read/transfer timeout) destroying zombie sockets.
    - RFC 7231 `Retry-After` header parsing with full jitter backoff for HTTP 429 rate limiting.
    - Drop-in implementations for `http` (`HttpSyncTransport`), `dio` (`DioSyncTransport`), and in-memory mock (`InMemorySyncTransport`).
  - **Layer 5: Application Facade (`OrbitClient` & `OfflineSyncClient`):**
    - Strongly-typed entity table handles (`OrbitTable<T>`) with compile-time safety.
    - Automated SQLite type sanitization (booleans, DateTime, nested maps/lists to JSON).
    - Reactive streaming queries with leading-immediate debounce (`leadingImmediateDebounce`).
    - SHA-256 hashed multi-tenant session sandboxing (`orbit_sessions/<hash>/orbit.db`).
    - Causal Horizon Guard soft-rejecting poison pills and holding dependent child mutations.
    - Isolated metadata tracking without touching host app `PRAGMA user_version`.
    - 4-step graceful drain protocol with 3-second hard budget in `close()`.
  - **Layer 6: Observability & Telemetry (`SyncObserver` & `SyncLogger`):**
    - Unified `Stream<SyncEvent>` and 14 typed streams across 5 domain categories.
    - Fixed-capacity circular buffer `SyncLogger` with non-blocking snapshot dumps.
    - Monotonic `SlaMonitor` evaluating business SLA warnings (80%) and breaches (100%).
    - Zero-SQL developer dashboard methods: `watchSummary()`, `getFailures()`, `retryAllFailed()`.
- **Zero-Codegen:**
  - Removed all required `build_runner` boilerplate. Standard Dart classes and maps work out of the box.
- **346 Automated Tests:**
  - 100% green test suite spanning unit tests, crash durability, network failure injection, multi-lane concurrency, and 3-way delta reconciliation.
- **Blueprint Engine Modernization:**
  - Strict Universal 5-Column JSON Document Store (`id`, `version`, `updated_at`, `expires_at`, `data_json`).
  - Hybrid Earliest-Deadline-First (EDF) scheduling with SLA escalation and 4-tier Priority Queue.
  - Multi-lane FIFO execution with cross-entity parallelism and zero head-of-line blocking.
  - Cleaned all legacy relational foreign-key scans and obsolete schema migrations.

## [0.1.0] - 2026-10-16

### Added
- Initial experimental prototype and storage spike.
