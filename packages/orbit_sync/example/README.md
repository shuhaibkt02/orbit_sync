# 🛰️ Orbit Sync Example App

A production-grade, Apple-inspired Flutter task manager demonstrating offline-first synchronization with **Orbit Sync**.

---

## ⚡ Quickstart (Runs 100% Out-of-the-Box)

No external backend, Docker container, or terminal server required! 
The app spins up a lightweight in-process mock server (`MockBackend`) on app launch so you can test synchronization immediately.

```bash
# Run on macOS, iOS, Android, or desktop
flutter run
```

---

## 📱 Features Demonstrated

1. **Instant Saves (0ms UI latency):**
   - Tasks are committed immediately to local SQLite WAL.
   - Zero loading spinners; optimistic UI updates.

2. **Invisible Background Synchronization:**
   - Queues outbox mutations atomically with domain records.
   - Automatically pushes mutations sequentially to the backend upon network connectivity.

3. **Real-time Sync Status & Telemetry:**
   - Tap the status pill in the top-right header to open the **Sync Telemetry Sheet**.
   - Monitor live metrics: Pending Outbox, Synced Records, and Dead-Letter Queue (DLQ).
   - Trigger manual force-sync or test data seeding.

4. **Connecting to Your Real Backend:**
   - Open `lib/main.dart` and point `baseUrl` to your company's REST API:
   ```dart
   final client = await OrbitClient.initialize(
     databasePath: p.join(dir.path, 'orbit_tasks.db'),
     baseUrl: 'https://api.yourcompany.com',
   );
   ```
