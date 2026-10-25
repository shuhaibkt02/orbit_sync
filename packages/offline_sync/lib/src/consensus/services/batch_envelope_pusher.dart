import 'dart:convert';
import 'dart:io';
import 'package:sqlite3/sqlite3.dart' show Row;
import '../../storage/sync_storage.dart';
import '../../sync_transport.dart';
import '../../sync_profile.dart';
import '../domain/models/sync_result.dart';
import '../domain/policies/backoff_policy.dart';
import 'custom_rest_pusher.dart';

/// Bundles pending mutations into a single unified JSON batch envelope (Mode 2: Batch Push).
class BatchEnvelopePusher {
  final SyncStorage storage;
  final SyncTransport transport;
  final SyncProfile profile;
  final BackoffPolicy backoffPolicy;
  final int currentSchemaVersion;
  final MutationMigrator? migrator;
  final Future<void> Function()? onAuthExpired;

  BatchEnvelopePusher({
    required this.storage,
    required this.transport,
    required this.profile,
    required this.backoffPolicy,
    this.currentSchemaVersion = 1,
    this.migrator,
    this.onAuthExpired,
  });

  Future<SyncPushResult> pushBatchEnvelope({
    required List<Row> pending,
    required List<String> mutationIds,
    required String placeholders,
    required int nowMs,
    String? chaos,
  }) async {
    final mutations = <Map<String, dynamic>>[];
    for (final r in pending) {
      final fromVersion = (r['schema_version'] as int?) ?? 1;
      final payloadJson = r['payload_json'] as String?;
      var payload = payloadJson != null ? (jsonDecode(payloadJson) as Map<String, dynamic>) : <String, dynamic>{};
      var targetVersion = fromVersion;

      if (fromVersion < currentSchemaVersion && migrator != null) {
        payload = migrator!(fromVersion, currentSchemaVersion, r['entity_name'] as String, payload);
        targetVersion = currentSchemaVersion;
        await storage.db.execute(
          'UPDATE _sync_outbox SET payload_json = ?, schema_version = ? WHERE mutation_id = ?',
          [jsonEncode(payload), currentSchemaVersion, r['mutation_id']],
        );
      }

      mutations.add({
        'entity': r['entity_name'],
        'id': r['entity_id'],
        'op': r['op'],
        'payload': payload,
        'version': r['base_version'],
        'schema_version': targetVersion,
      });
    }

    final idempotencyKey = mutationIds.length == 1 ? mutationIds.first : 'batch-${mutationIds.first}';

    try {
      final resp = await transport.pushBatch(
        mutations: mutations,
        idempotencyKey: idempotencyKey,
        chaos: chaos,
      );
      if (resp.error != null) {
        throw resp.error is Exception ? resp.error as Exception : Exception(resp.error.toString());
      }

      final respBody = resp.body;
      final bodyJson = respBody.isNotEmpty ? (jsonDecode(respBody) as Map<String, dynamic>) : <String, dynamic>{};

      if (resp.statusCode == HttpStatus.upgradeRequired) {
        await storage.db.execute("UPDATE _sync_outbox SET status = 'pending' WHERE mutation_id IN ($placeholders)", mutationIds);
        return SyncPushResult(status: SyncPushStatus.needsUpgrade, errorMessage: respBody);
      }
      if (resp.statusCode == HttpStatus.unauthorized) {
        await storage.db.execute("UPDATE _sync_outbox SET status = 'pending' WHERE mutation_id IN ($placeholders)", mutationIds);
        await onAuthExpired?.call();
        return const SyncPushResult(status: SyncPushStatus.unauthorized);
      }
      if (resp.statusCode == HttpStatus.tooManyRequests) {
        final nextRetry = CustomRestPusher.parseNextRetryAfter(resp.headers['retry-after'], nowMs, backoffPolicy);
        await storage.db.execute(
          "UPDATE _sync_outbox SET status = 'pending', next_retry_at = ? WHERE mutation_id IN ($placeholders)",
          [nextRetry, ...mutationIds],
        );
        return const SyncPushResult(status: SyncPushStatus.networkError, errorMessage: 'Rate limited (HTTP 429)');
      }
      if (resp.statusCode == HttpStatus.badRequest) {
        final targetStatus = (profile == SyncProfile.basic) ? 'failed' : 'dlq';
        await storage.db.execute(
          'UPDATE _sync_outbox SET status = ?, next_retry_at = NULL, error_details_json = ? WHERE mutation_id = ?',
          [targetStatus, respBody, mutationIds.first],
        );
        if (mutationIds.length > 1) {
          final rem = mutationIds.sublist(1);
          final remPh = List.filled(rem.length, '?').join(', ');
          await storage.db.execute("UPDATE _sync_outbox SET status = 'pending' WHERE mutation_id IN ($remPh)", rem);
        }
        return SyncPushResult(status: SyncPushStatus.poisonPill, errorMessage: respBody);
      }
      if (resp.statusCode == HttpStatus.conflict) {
        return SyncPushResult(status: SyncPushStatus.conflict, details: bodyJson);
      }
      if (resp.statusCode == HttpStatus.unprocessableEntity) {
        await storage.rollbackOptimistic(mutationIds.first, status: 'validation_error');
        await storage.db.execute(
          'UPDATE _sync_outbox SET next_retry_at = NULL, error_details_json = ? WHERE mutation_id = ?',
          [respBody, mutationIds.first],
        );
        return SyncPushResult(status: SyncPushStatus.validationError, details: bodyJson);
      }
      if (resp.statusCode == HttpStatus.ok) {
        await storage.db.execute("UPDATE _sync_outbox SET status = 'synced', next_retry_at = NULL WHERE mutation_id IN ($placeholders)", mutationIds);
        return SyncPushResult(status: SyncPushStatus.success, applied: mutations.length);
      }

      throw HttpException('HTTP ${resp.statusCode}: $respBody');
    } catch (e) {
      for (final r in pending) {
        final mutId = r['mutation_id'] as String;
        final currentRetry = (r['retry_count'] as int?) ?? 0;
        final newRetry = currentRetry + 1;
        final targetStatus = (newRetry >= backoffPolicy.maxRetries) ? 'dlq' : 'pending';
        final nextRetry = (targetStatus == 'dlq') ? null : backoffPolicy.nextRetryAt(newRetry, nowMs);
        await storage.db.execute(
          'UPDATE _sync_outbox SET status = ?, retry_count = ?, next_retry_at = ? WHERE mutation_id = ?',
          [targetStatus, newRetry, nextRetry, mutId],
        );
      }
      return SyncPushResult(status: SyncPushStatus.networkError, errorMessage: e.toString());
    }
  }
}
