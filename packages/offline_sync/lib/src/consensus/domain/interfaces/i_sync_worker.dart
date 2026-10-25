import '../models/sync_result.dart';

/// Abstract contract for Layer 2 synchronization and consensus engine.
abstract class ISyncWorker {
  /// Checkpointed sync cursor from metadata.
  Future<int> getLastSyncedCursor();

  /// Updates checkpointed sync cursor.
  Future<void> setLastSyncedCursor(int cursor);

  /// Pushes up to [batchSize] pending mutations to the remote transport.
  Future<SyncPushResult> pushBatch({
    int batchSize = 10,
    String? chaos,
    bool force = false,
  });

  /// Pulls a single page of remote changes and performs 3-way reconciliation.
  Future<SyncPullResult> pullPage({String? chaos});

  /// Continuously drains remote changelog pages until exhausted.
  Future<int> pullAll();

  /// Performs atomic generation-swap table re-seeding on HTTP 410 Gone.
  Future<bool> resyncGeneration(List<String> entities);

  /// Executes full push-then-pull bidirectional sync cycle.
  Future<void> sync({bool force = false});

  /// Releases worker and transport resources.
  void dispose();
}
