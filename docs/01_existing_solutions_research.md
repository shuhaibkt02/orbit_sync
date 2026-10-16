# Phase 1: Research on Existing Offline-First Solutions

## 1. Overview
To build a developer-friendly, production-grade Flutter offline-first plugin, we first analyze existing tools in the Flutter and mobile ecosystem. 

The goal is to:
- Identify what they do well (**The Good**).
- Identify their pain points and limitations (**The Bad**).
- Pinpoint the exact gap our plugin will fill for any developer (from small indie apps to large enterprise apps).

---

## 2. Evaluation of Existing Solutions

### A. PowerSync (`powersync_flutter`)
* **How it works:** Replicates a backend database (Postgres, MongoDB, etc.) to an on-device SQLite database via a dedicated sync service.
* **The Good:**
  - Fast client reads using native SQLite via `dart:ffi`.
  - Reactive queries (`watch()`) update Flutter UI automatically on data change.
  - Solid conflict handling and schema sync.
* **The Bad:**
  - **Requires dedicated backend infrastructure:** Developers cannot just plug it into their existing standard REST or GraphQL API. They must deploy and maintain the PowerSync Sync Service.
  - **High vendor/operational dependency:** Not truly backend-agnostic.

---

### B. Brick (`brick_offline_first`)
* **How it works:** A Flutter repository pattern that bridges SQLite (via Drift or Sqflite) with REST or GraphQL APIs.
* **The Good:**
  - Uses code generation (`@ConnectOfflineFirstWithRest`) to minimize boilerplate.
  - Developers query through one repository (`repository.get<User>()`).
  - Supports standard REST APIs without a dedicated sync server.
* **The Bad:**
  - **Brittle queue & sync engine:** The offline request queue is basic; handling multi-table transactional writes, DAG dependency ordering, and dead letters is complex and prone to data corruption.
  - **Limited conflict resolution:** No built-in delta sync, vector clocks, or robust server-version comparison.
  - **Boilerplate & build times:** Heavy reliance on `build_runner` for every model adapter.

---

### C. AWS Amplify DataStore
* **How it works:** Local storage engine that synchronizes automatically with AWS AppSync GraphQL and DynamoDB.
* **The Good:**
  - Full delta sync support with automatic versioning (`_version`, `_deleted`, `_lastChangedAt`).
  - Clean out-of-the-box conflict resolution strategies (Auto Merge, Optimistic Concurrency, Custom Lambda).
* **The Bad:**
  - **Strict vendor lock-in:** Only works with AWS services. Unusable for standard backends (Node.js, Go, Django, Supabase, Laravel, etc.).
  - **Heavy SDK size:** Significant footprint and slow cold start on mobile devices.

---

### D. Couchbase Lite (`cbl` / `cbl_flutter`)
* **How it works:** Embedded NoSQL document database running locally with replication to Couchbase Sync Gateway.
* **The Good:**
  - Enterprise-grade reliability, encryption, and peer-to-peer sync capability.
  - Robust live queries and replication listeners.
* **The Bad:**
  - **Large binary footprint:** Embedded C/C++ engine adds significant megabytes to the APK/IPA.
  - **Document-only model:** Relational data and complex join queries are cumbersome compared to SQLite.
  - **Licensing and backend complexity:** Requires enterprise Couchbase backend for production sync.

---

### E. ElectricSQL
* **How it works:** Syncs Postgres directly to local SQLite using active-active replication and CRDT-based conflict resolution.
* **The Good:**
  - High degree of data consistency using partial replication shapes.
  - Native SQLite developer experience.
* **The Bad:**
  - **Postgres-only:** Requires an Elixir-based sync proxy tied directly to Postgres logical replication.
  - Unsuitable for standard RESTful/GraphQL microservice architectures.

---

### F. DIY Approach (Raw Drift / SQLite + Dio + Outbox Queue)
* **How it works:** How 90% of developers currently build offline apps today.
* **The Good:**
  - Maximum flexibility; fits whatever backend the team already has.
* **The Bad:**
  - **Massive engineering effort:** Takes 3–6 months to build and test.
  - **High bug frequency:** Developers routinely get caught on edge cases (silent queue stalls, dropped frames on heavy sync, duplicate writes, foreign key corruption, app killed mid-sync).

---

## 3. Comparative Summary Matrix

| Solution | Backend-Agnostic (Standard REST/GraphQL)? | Zero Infrastructure Required? | Reactive Flutter UI? | Robust Outbox & Conflicts? | Relational SQLite Underneath? |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **PowerSync** | ❌ No | ❌ No (Sync Service) | ✅ Yes | ✅ Yes | ✅ Yes |
| **Brick** | ✅ Yes | ✅ Yes | ⚠️ Partial | ❌ No (Basic) | ✅ Yes |
| **Amplify DataStore** | ❌ No (AWS only) | ❌ No (AWS only) | ✅ Yes | ✅ Yes | ❌ No (Doc Store) |
| **Couchbase Lite** | ❌ No (Couchbase) | ❌ No (Sync Gateway) | ✅ Yes | ✅ Yes | ❌ No (Doc Store) |
| **ElectricSQL** | ❌ No (Postgres only) | ❌ No (Sync Proxy) | ✅ Yes | ✅ Yes | ✅ Yes |
| **Our Target Plugin** | **✅ YES (Adapter-based)** | **✅ YES** | **✅ YES** | **✅ YES (Production-grade)** | **✅ YES (Fast FFI SQLite)** |

---

## 4. Key Takeaways & Our Design Strategy

1. **Adopt from the best:**
   - Use **SQLite with `dart:ffi`** for local storage (proven speed and reliability across PowerSync, Drift, and ElectricSQL).
   - Provide **reactive streams** (`watchQuery`) so Flutter widgets re-render automatically on local updates.
   - Use **client-generated UUIDv7** to make all offline creations collision-proof.

2. **Fix the flaws of existing tools:**
   - **No mandatory backend servers:** Use a **Pluggable Network Adapter** interface (`SyncNetworkAdapter`). Developers write a simple 20-line bridge to their existing REST or GraphQL endpoints.
   - **Bulletproof Outbox:** Implement a durable queue with idempotency keys, DAG dependency awareness (parent before child), exponential backoff, and dead-letter queues.
   - **Off-UI Isolate Sync:** Heavy batch processing and serialization happen in a background Dart isolate to guarantee 60/120fps UI smoothness.
   - **Simple Developer Experience (DX):** Setup must take fewer than 30 lines of code without requiring massive build times or heavy infrastructure.
