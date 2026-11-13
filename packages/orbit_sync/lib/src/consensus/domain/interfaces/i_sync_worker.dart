import '../models/sync_result.dart';
import 'i_conflict_resolver.dart';

/// Abstract contract for Layer 5 synchronization and consensus engine.
abstract class ISyncWorker {
  /// Checkpointed sync cursor from metadata.
  Future<int> getLastSyncedCursor();

  /// Updates checkpointed sync cursor.
  Future<void> setLastSyncedCursor(int cursor);

  /// Registers a custom entity-specific CRDT or join-semilattice conflict resolver.
  void registerConflictResolver(String entity, EntityConflictResolver resolver);

  /// Reclaims stranded in_flight mutations older than 60s back to pending status.
  Future<int> reclaimZombies();

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
