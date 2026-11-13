import '../../../storage/sync_storage.dart';

/// Guard protecting local optimistic state against destructive split-brain
/// rollback when older in-flight mutations permanently fail (Challenge 6).
class CausalHorizonGuard {
  final SyncStorage storage;

  const CausalHorizonGuard(this.storage);

  /// Checks if newer local mutations exist for the given entity record.
  /// If true, rolling back to an older baseline would destroy newer local edits.
  Future<bool> hasNewerPendingMutations({
    required String entity,
    required String id,
    required int failedCreatedAtMs,
  }) async {
    final rows = await storage.db.getAll(
      "SELECT COUNT(*) as cnt FROM _sync_outbox WHERE entity_name = ? AND entity_id = ? AND created_at > ? AND status IN ('pending', 'in_flight')",
      [entity, id, failedCreatedAtMs],
    );
    final count = (rows.first['cnt'] as int?) ?? 0;
    return count > 0;
  }

  /// Softly marks an outbox mutation as rejected rather than hard-deleting it,
  /// preserving user input in the form/draft state.
  Future<void> softRejectRecord({
    required String entity,
    required String id,
    String? errorMessage,
  }) async {
    SyncValidator.validateEntity(entity);
    SyncValidator.validateId(id);
    try {
      await storage.db
          .execute('ALTER TABLE "$entity" ADD COLUMN _sync_status TEXT');
    } catch (_) {}
    try {
      await storage.db
          .execute('ALTER TABLE "$entity" ADD COLUMN _sync_error TEXT');
    } catch (_) {}

    await storage.db.execute(
      'UPDATE "$entity" SET _sync_status = \'rejected\', _sync_error = ? WHERE id = ?',
      [errorMessage ?? 'Validation failed', id],
    );

    await storage.db.writeTransaction((tx) async {
      await tx.execute(
        "UPDATE _sync_outbox SET status = 'validation_error', error_details_json = ? WHERE entity_name = ? AND entity_id = ? AND status IN ('pending', 'in_flight', 'held')",
        [errorMessage ?? 'Validation failed', entity, id],
      );
    });
  }

  /// Holds all child mutations whose parent was permanently rejected using
  /// recursive CTE traversal, preventing 404/400 errors downstream.
  Future<int> holdDescendantMutations(String parentMutationId) async {
    final result = await storage.db.writeTransaction<int>((tx) async {
      await tx.execute('''
        WITH RECURSIVE descendants(mutation_id) AS (
          SELECT mutation_id FROM _sync_outbox WHERE depends_on_mutation_id = ?
          UNION ALL
          SELECT o.mutation_id FROM _sync_outbox o JOIN descendants d ON o.depends_on_mutation_id = d.mutation_id
        )
        UPDATE _sync_outbox SET status = 'held' WHERE mutation_id IN (SELECT mutation_id FROM descendants);
      ''', [parentMutationId]);
      final cntRow = await tx.get('SELECT changes() as cnt;');
      return (cntRow['cnt'] as int?) ?? 0;
    });
    return result;
  }
}
