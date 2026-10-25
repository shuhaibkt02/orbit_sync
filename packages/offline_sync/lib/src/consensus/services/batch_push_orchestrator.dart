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
  }) {
    _customPusher = CustomRestPusher(
      storage: storage,
      transport: transport,
      profile: profile,
      backoffPolicy: backoffPolicy,
      onAuthExpired: onAuthExpired,
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

  Future<SyncPushResult> pushBatch({
    int batchSize = 10,
    String? chaos,
    bool force = false,
  }) async {
    final nowMs = _nowMs;

    final pending = await storage.db.writeTransaction<List<Row>>((tx) async {
      if (profile == SyncProfile.enterprise) {
        await tx.execute('''
          UPDATE _sync_outbox 
          SET status = 'pending' 
          WHERE status = 'held' 
            AND depends_on_mutation_id IN (SELECT mutation_id FROM _sync_outbox WHERE status = 'synced');
        ''');
      }

      final pendingRaw = await tx.getAll(
        force
            ? "SELECT * FROM _sync_outbox WHERE status = 'pending' ORDER BY priority DESC, created_at ASC LIMIT ?"
            : "SELECT * FROM _sync_outbox WHERE status = 'pending' AND (next_retry_at IS NULL OR next_retry_at <= ?) AND (dispatch_after IS NULL OR dispatch_after <= ?) ORDER BY priority DESC, created_at ASC LIMIT ?",
        force ? [batchSize * 2] : [nowMs, nowMs, batchSize * 2],
      );

      if (pendingRaw.isEmpty) return const [];

      final eligible = <Row>[];
      for (final r in pendingRaw) {
        if (profile == SyncProfile.enterprise) {
          final parentId = r['depends_on_mutation_id'] as String?;
          if (parentId != null) {
            final parentRows = await tx.getAll(
              'SELECT status FROM _sync_outbox WHERE mutation_id = ?',
              [parentId],
            );
            if (parentRows.isNotEmpty) {
              final pStatus = parentRows.first['status'] as String;
              if (pStatus == 'dlq' || pStatus == 'conflict' || pStatus == 'held') {
                await tx.execute(
                  "UPDATE _sync_outbox SET status = 'held' WHERE mutation_id = ?",
                  [r['mutation_id']],
                );
                continue;
              }
            }
          }
        }
        eligible.add(r);
        if (eligible.length == batchSize) break;
      }

      if (eligible.isEmpty) return const [];

      final mutationIds = eligible.map((r) => r['mutation_id'] as String).toList();
      final placeholders = List.filled(mutationIds.length, '?').join(', ');
      await tx.execute(
        "UPDATE _sync_outbox SET status = 'in_flight' WHERE mutation_id IN ($placeholders) AND status = 'pending'",
        mutationIds,
      );

      return eligible;
    });

    if (pending.isEmpty) {
      return const SyncPushResult(status: SyncPushStatus.success, applied: 0);
    }

    final mutationIds = pending.map((r) => r['mutation_id'] as String).toList();
    final placeholders = List.filled(mutationIds.length, '?').join(', ');

    final SyncPushResult result;
    if (pending.any((r) => r['endpoint_url'] != null)) {
      result = await _customPusher.pushCustomEndpoints(
        pending: pending,
        mutationIds: mutationIds,
        placeholders: placeholders,
        nowMs: nowMs,
      );
    } else {
      result = await _batchPusher.pushBatchEnvelope(
        pending: pending,
        mutationIds: mutationIds,
        placeholders: placeholders,
        nowMs: nowMs,
        chaos: chaos,
      );
    }

    if (result.status == SyncPushStatus.success && result.applied > 0) {
      onLog?.call('Successfully pushed ${result.applied} mutations');
    }
    return result;
  }
}
