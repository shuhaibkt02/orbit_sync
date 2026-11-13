# 🛰️ FakeSyncServer (Automated Test Harness)

This package contains the lightweight mock sync server used exclusively for unit, integration, and scenario testing in Orbit Sync.

## ⚡ Zero-Setup Automated Testing

When running automated tests with `dart test`, **no manual server execution is required**.

Every test suite (`test/consensus/`, `test/services/`, etc.) automatically boots an ephemeral in-process `FakeSyncServer` on an available OS port (`port: 0`) and gracefully terminates it upon test completion:

```dart
// Handled automatically inside test setUp / tearDown:
final server = await FakeSyncServer.start(port: 0);
// ... tests run against server.baseUrl ...
await server.stop();
```

## 🛠️ Optional Standalone Execution

If you need to manually inspect or debug REST endpoints via `curl` or Postman, you can start the mock server standalone:

```bash
dart test/sync_server/bin/server.dart
```

Listening on `http://127.0.0.1:8080`.
