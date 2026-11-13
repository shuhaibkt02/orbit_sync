import 'package:sqlite3/sqlite3.dart' show Row;
import '../../storage/sync_storage.dart';
import '../../transport/sync_transport.dart';
import '../../sync_profile.dart';
import '../domain/models/sync_result.dart';
import '../domain/policies/backoff_policy.dart';
import 'custom_rest_pusher.dart';
import 'batch_envelope_pusher.dart';

/// Push orchestrator coordinating candidate outbox claiming and dispatch delegation.
class BatchPushOrchestrator {
  final SyncStorage storage;
  final SyncTransport transport;
  final SyncProfile profile;
  final BackoffPolicy backoffPolicy;
  final void Function(String message)? onLog;
  final Future<void> Function()? onAuthExpired;
  final int Function()? nowMsProvider;
  final int maxConcurrentLanes;

  int get currentSchemaVersion => _batchPusher.currentSchemaVersion;
  set currentSchemaVersion(int v) => _batchPusher.currentSchemaVersion = v;

  MutationMigrator? get migrator => _batchPusher.migrator;
  set migrator(MutationMigrator? m) => _batchPusher.migrator = m;

  late final CustomRestPusher _customPusher;
  late final BatchEnvelopePusher _batchPusher;

  BatchPushOrchestrator({
    required this.storage,
    required this.transport,
    required this.profile,
    required this.backoffPolicy,
    int currentSchemaVersion = 1,
    MutationMigrator? migrator,
    this.onLog,
    this.onAuthExpired,
    this.nowMsProvider,
    this.maxConcurrentLanes = 4,
  }) {
    _customPusher = CustomRestPusher(
      storage: storage,
      transport: transport,
      profile: profile,
      backoffPolicy: backoffPolicy,
      onAuthExpired: onAuthExpired,
      maxConcurrentLanes: maxConcurrentLanes,
    );
    _batchPusher = BatchEnvelopePusher(
      storage: storage,
      transport: transport,
      profile: profile,
      backoffPolicy: backoffPolicy,
      currentSchemaVersion: currentSchemaVersion,
      migrator: migrator,
      onAuthExpired: onAuthExpired,
    );
  }

  int get _nowMs => nowMsProvider?.call() ?? DateTime.now().toUtc().millisecondsSinceEpoch;

  void registerIdExtractor(String entity, String? Function(dynamic json) extractor) {
    _customPusher.registerIdExtractor(entity, extractor);
  }

  /// Reclaims stranded in_flight mutations older than 60s (or with updated_at = 0) back to pending status.
  Future<int> reclaimZombies() async {
    final now = _nowMs;
    final timeoutMs = 60 * 1000;
    final cutoff = now - timeoutMs;
    return await storage.db.writeTransaction<int>((tx) async {
      final rows = await tx.getAll(
        "SELECT mutation_id FROM _sync_outbox WHERE status = 'in_flight' AND (updated_at = 0 OR updated_at < ?)",
        [cutoff],
      );
      if (rows.isEmpty) return 0;
      await tx.execute(
        "UPDATE _sync_outbox SET status = 'pending', updated_at = ? WHERE status = 'in_flight' AND (updated_at = 0 OR updated_at < ?)",
        [now, cutoff],
      );
      return rows.length;
    });
  }

  Future<SyncPushResult> pushBatch({
    int batchSize = 10,
    String? chaos,
    bool force = false,
    int? maxConcurrentLanes,
  }) async {
    await reclaimZombies();
    final nowMs = _nowMs;

    final pending = await storage.db.writeTransaction<List<Row>>((tx) async {
      await tx.execute('''
        UPDATE _sync_outbox 
        SET status = 'pending', updated_at = ? 
        WHERE status = 'held' 
          AND depends_on_mutation_id IN (SELECT mutation_id FROM _sync_outbox WHERE status = 'synced');
      ''', [nowMs]);

      final pendingRaw = await tx.getAll(
        force
            ? '''
              SELECT * FROM _sync_outbox 
              WHERE status = 'pending' 
              ORDER BY 
                CASE 
                  WHEN (created_at + (sla_seconds * 1000)) - ? < 900000 THEN 1 
                  ELSE 0 
                END DESC,
                priority DESC,
                (created_at + (sla_seconds * 1000)) ASC,
                sequence_id ASC
              LIMIT ?
            '''
            : '''
              SELECT * FROM _sync_outbox 
              WHERE status = 'pending' 
                AND (next_retry_at IS NULL OR next_retry_at <= ?)
                AND (dispatch_after IS NULL OR dispatch_after <= ?)
              ORDER BY 
                CASE 
                  WHEN (created_at + (sla_seconds * 1000)) - ? < 900000 THEN 1 
                  ELSE 0 
                END DESC,
                priority DESC,
                (created_at + (sla_seconds * 1000)) ASC,
                sequence_id ASC
              LIMIT ?
            ''',
        force ? [nowMs, batchSize * 2] : [nowMs, nowMs, nowMs, batchSize * 2],
      );

      if (pendingRaw.isEmpty) return const [];

      final eligible = <Row>[];
      for (final r in pendingRaw) {
        final parentId = r['depends_on_mutation_id'] as String?;
        if (parentId != null) {
          final parentRows = await tx.getAll(
            'SELECT status FROM _sync_outbox WHERE mutation_id = ?',
            [parentId],
          );
          if (parentRows.isEmpty || parentRows.first['status'] != 'synced') {
            await tx.execute(
              "UPDATE _sync_outbox SET status = 'held', updated_at = ? WHERE mutation_id = ?",
              [nowMs, r['mutation_id']],
            );
            continue;
          }
        }
        eligible.add(r);
        if (eligible.length == batchSize) break;
      }

      if (eligible.isEmpty) return const [];

      final mutationIds = eligible.map((r) => r['mutation_id'] as String).toList();
      final placeholders = List.filled(mutationIds.length, '?').join(', ');
      await tx.execute(
        "UPDATE _sync_outbox SET status = 'in_flight', updated_at = ? WHERE mutation_id IN ($placeholders) AND status = 'pending'",
        [nowMs, ...mutationIds],
      );

      return eligible;
    });

    if (pending.isEmpty) {
      return const SyncPushResult(status: SyncPushStatus.success, applied: 0);
    }

    final mutationIds = pending.map((r) => r['mutation_id'] as String).toList();
    final placeholders = List.filled(mutationIds.length, '?').join(', ');

    final customPending = pending.where((r) => r['endpoint_url'] != null).toList();
    final batchPending = pending.where((r) => r['endpoint_url'] == null).toList();

    SyncPushResult? customResult;
    SyncPushResult? batchResult;

    try {
      if (customPending.isNotEmpty) {
        final cIds = customPending.map((r) => r['mutation_id'] as String).toList();
        final cPh = List.filled(cIds.length, '?').join(', ');
        customResult = await _customPusher.pushCustomEndpoints(
          pending: customPending,
          mutationIds: cIds,
          placeholders: cPh,
          nowMs: nowMs,
          maxConcurrentLanes: maxConcurrentLanes,
        );
      }

      if (batchPending.isNotEmpty && (customResult == null || customResult.status != SyncPushStatus.unauthorized)) {
        final bIds = batchPending.map((r) => r['mutation_id'] as String).toList();
        final bPh = List.filled(bIds.length, '?').join(', ');
        batchResult = await _batchPusher.pushBatchEnvelope(
          pending: batchPending,
          mutationIds: bIds,
          placeholders: bPh,
          nowMs: nowMs,
          chaos: chaos,
        );
      }
    } finally {
      await storage.db.execute(
        "UPDATE _sync_outbox SET status = 'pending', updated_at = ? WHERE mutation_id IN ($placeholders) AND status = 'in_flight'",
        [_nowMs, ...mutationIds],
      );
    }

    final totalApplied = (customResult?.applied ?? 0) + (batchResult?.applied ?? 0);
    final errorResult = [customResult, batchResult].firstWhere(
      (r) => r != null && r.status != SyncPushStatus.success,
      orElse: () => null,
    );

    final result = errorResult != null
        ? SyncPushResult(status: errorResult.status, applied: totalApplied, errorMessage: errorResult.errorMessage)
        : SyncPushResult(status: SyncPushStatus.success, applied: totalApplied);

    if (result.status == SyncPushStatus.success && result.applied > 0) {
      onLog?.call('Successfully pushed ${result.applied} mutations');
    }
    return result;
  }
}
