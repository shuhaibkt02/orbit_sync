# Phase 9: Master Blueprint & Solving the Codegen DX Tension

## 1. Validating the Insight: The build_runner Tension
Brick was criticized for `build_runner` bloat because:
1. Every model required multiple separate builders (one for REST, one for SQLite, one for adapters).
2. It forced a full project re-index even for trivial changes.
3. The generated code was purely for mapping/serialization, offering zero sync or testing intelligence.

---

## 2. How Our Plugin Solves the Codegen Performance Problem

To keep DX ultra-fast and lightweight, our plugin implements a **Two-Path Model**:

### Path A: Zero-Codegen Runtime Mode (Instant / Beginner)
For developers who want to avoid `build_runner` altogether:
```dart
// Works immediately without running build_runner!
final sync = await OfflineSync.init(baseUrl: 'https://api.example.com');

sync.registerEntity(
  table: 'tasks',
  endpoint: '/tasks',
  fromJson: Task.fromJson,
  toJson: (t) => t.toJson(),
);
```

### Path B: Codegen Mode (Type-Safe & Automated Test Generation)
For developers and teams who want:
- Compile-time type safety.
- Zero boilerplate SQLite bindings.
- **Automated test suite generation** (`dart test`).
- Fast, scoped builder execution (only processes files annotated with `@SyncEntity`, skipping the rest of the project).

---

## 3. The Unified Project Architecture (Master Blueprint)

```
offline_plugin/
├── packages/
│   ├── offline_sync/                   # Core client runtime package (published to pub.dev)
│   │   ├── lib/
│   │   │   ├── src/
│   │   │   │   ├── core/               # Public API & OfflineSync orchestrator
│   │   │   │   ├── database/           # SQLite (dart:ffi), WAL mode, transaction wrapper
│   │   │   │   ├── outbox/             # Transactional Outbox, DAG queue, retry engine
│   │   │   │   ├── sync/               # Delta sync, cursors, push/pull protocols
│   │   │   │   ├── conflicts/          # Field-level merge & custom hook resolvers
│   │   │   │   ├── isolates/           # Background sync worker isolate
│   │   │   │   ├── transport/          # Pluggable SyncTransport interface (REST, etc.)
│   │   │   │   └── profiles/           # SyncProfile: basic, standard, enterprise
│   │   │   └── offline_sync.dart       # Main barrel file
│   │   └── pubspec.yaml
│   │
│   ├── offline_sync_annotation/        # Lightweight annotation package (@SyncEntity)
│   │   ├── lib/
│   │   │   └── offline_sync_annotation.dart
│   │   └── pubspec.yaml
│   │
│   └── offline_sync_generator/         # build_runner code generator & test generator
│       ├── lib/
│       │   ├── src/
│       │   │   ├── entity_generator.dart       # Generates SQLite tables & repositories
│       │   │   └── test_suite_generator.dart   # Generates automated unit & chaos tests
│       │   └── builder.dart
│       └── pubspec.yaml
```

---

## 4. Final Verdict: Ready to Build
We have validated:
- **Market Gap:** Unclaimed space in Flutter.
- **Protocol:** WatermelonDB delta protocol + Python transactional outbox.
- **Reliability:** Background isolate + SQLite WAL mode.
- **DX:** Dual-path (runtime or codegen) + automated test generation.
- **Flexibility:** Works with any backend without vendor lock-in.
