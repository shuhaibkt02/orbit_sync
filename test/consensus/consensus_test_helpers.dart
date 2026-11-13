import 'dart:io';
import 'package:orbit_sync/orbit_sync.dart';
import '../sync_server/lib/sync_server.dart';

/// Test environment bundle for Layer 2 consensus test suites.
class TestConsensusEnv {
  final Directory tempDir;
  final FakeSyncServer server;
  final SyncStorage storage;
  final SyncWorker worker;

  TestConsensusEnv({
    required this.tempDir,
    required this.server,
    required this.storage,
    required this.worker,
  });

  static Future<TestConsensusEnv> create({
    int maxReaders = 4,
    int pullPageLimit = 50,
    Map<String, String>? taskColumns,
  }) async {
    final tempDir = Directory.systemTemp.createTempSync('consensus_test_');
    final server = await FakeSyncServer.start(port: 0);

    final storage = await SyncStorage.open(
      path: '${tempDir.path}/client.db',
      maxReaders: maxReaders,
    );

    await storage.registerEntityTable(
        'tasks',
        taskColumns ??
            {
              'title': 'TEXT',
              'dept': 'TEXT',
              'priority': 'TEXT',
              'start_time': 'TEXT',
              'end_time': 'TEXT',
            });

    final worker = SyncWorker(
      storage: storage,
      baseUrl: server.baseUrl,
      pullPageLimit: pullPageLimit,
    );

    return TestConsensusEnv(
      tempDir: tempDir,
      server: server,
      storage: storage,
      worker: worker,
    );
  }

  Future<void> dispose() async {
    worker.dispose();
    await storage.close();
    await server.stop();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  }
}
