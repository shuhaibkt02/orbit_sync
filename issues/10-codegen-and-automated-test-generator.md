# 10: Codegen Companion Packages & Automated Test Generator (Path B)

**What to build:**
Implement the Path B Codegen and Automated Test Generation companion packages:
1. `packages/offline_sync_annotation`:
   - `@SyncEntity(endpoint: '...', tableName: '...', profile: '...')`
   - `@PrimaryKey()`
   - `@SyncField(name: '...', isIgnored: false)`
2. `packages/offline_sync_generator`:
   - AST parser extracting model fields, types, and annotations.
   - Generates `.sync.g.dart` containing:
     - Table schema registration (`$TaskTableSchema`).
     - Map serialization (`$TaskFromMap`, `$TaskToMap`).
     - Type-safe repository (`$TaskRepository`) with `save()`, `delete()`, `getById()`, `getAll()`, `watchAll()`, `watchById()`.
     - Automated test suite generator (`$TaskSyncTestSuite`).
   - Standard `build.yaml` builder configuration for `build_runner`.
3. Acceptance tests verifying code generation and automated test execution.

**Blocked by:**
- 09: SyncProfile Tiers (Basic, Standard, Enterprise)

**Status:** done

### Acceptance Criteria:
- [x] **offline_sync_annotation Package:** Lightweight annotation package created and verified.
- [x] **offline_sync_generator Package:** `build_runner` generator created with AST analyzer and `build.yaml`.
- [x] **Type-Safe Repository Generation:** Generates type-safe CRUD and reactive `watchAll()` streams.
- [x] **Automated Test Suite Generation:** Generates automated test suite verifying offline save, push sync, conflict merge, and tombstones.
- [x] **Integration Verification:** Complete test verifying code generation and test execution.
