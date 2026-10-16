# Phase 20: Storage Candidates Empirical Benchmark (Item 1)

**Question:** Can each storage candidate handle dynamic runtime tables (`registerEntity` without codegen) and provide reactive streams?

**Harness:** `.scratch/spikes/storage_candidates/bin/test_storage_candidates.dart`

---

## 1. Empirical Results

```text
=== Running Storage Candidates Comparison Test ===

[1] Candidate 1: Raw sqlite3 + Custom Invalidation
  Emissions observed: [0, 1, 2] (Expected: [0, 1, 2])
  -> PASS: Raw sqlite3 works dynamically when paired with our own invalidation stream.

[2] Candidate 2: Drift Dynamic Database (Testing Zero-Codegen Reactivity)
  Emissions observed: [0] (Expected: [0, 1, 2], Got: [0])
  -> FAIL: Drift customSelect().watch() emitted only once [0] and missed all subsequent updates.
     Drift's readsFrom requires Set<ResultSetImplementation> (compile-time generated TableInfo classes).

[3] Candidate 3: sqlite_async (Dedicated Writer Isolate + Native Update Hooks)
  Emissions observed: [0, 1, 2] (Expected: [0, 1, 2])
  -> PASS: sqlite_async db.watch() automatically parses SQL, extracts table names, and emits updates [0, 1, 2] without codegen.
```

---

## 2. Decision Matrix

| Candidate | Runtime Dynamic Tables? | Zero-Codegen Reactive Streams? | Dedicated Writer Isolate? | Verdict |
| :--- | :---: | :---: | :---: | :--- |
| **Drift** | Yes | ❌ **No** (`readsFrom` requires generated `TableInfo`) | Yes | **Rejected for zero-codegen sync core** (requires code-gen). |
| **Raw `sqlite3`** | Yes | ⚠️ Custom (`StreamController`) | Must build ourselves | **Viable, but requires maintaining connection pool & isolate bridge**. |
| **`sqlite_async`** | **Yes** | ✅ **Yes** (`db.watch()` works out of the box) | **Built-in** | **Winner.** Solves single-writer isolate, reader pooling, and dynamic query streams natively. |
