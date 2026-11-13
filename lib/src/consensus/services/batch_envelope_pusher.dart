import 'dart:convert';
import 'dart:io';
import 'package:sqlite3/sqlite3.dart' show Row;
import '../../storage/sync_storage.dart';
import '../../transport/sync_transport.dart';
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
  int currentSchemaVersion;
  MutationMigrator? migrator;
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
      var payload = payloadJson != null
          ? (jsonDecode(payloadJson) as Map<String, dynamic>)
          : <String, dynamic>{};
      var targetVersion = fromVersion;

      if (fromVersion < currentSchemaVersion && migrator != null) {
        payload = migrator!(fromVersion, currentSchemaVersion,
            r['entity_name'] as String, payload);
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
        'payload': sanitizePayload(payload),
        'version': r['base_version'],
        'schema_version': targetVersion,
      });
    }

    final idempotencyKey = mutationIds.length == 1
        ? mutationIds.first
        : 'batch-${(mutationIds.toList()..sort()).join(':')}';

    final TransportResponse resp;
    try {
      resp = await transport.pushBatch(
        mutations: mutations,
        idempotencyKey: idempotencyKey,
        chaos: chaos,
      );
    } catch (_) {
      rethrow;
    }

    try {
      if (resp.error != null) {
        throw resp.error is Exception
            ? resp.error as Exception
            : Exception(resp.error.toString());
      }

      final respBody = resp.body;
      final bodyJson = respBody.isNotEmpty
          ? (jsonDecode(respBody) as Map<String, dynamic>)
          : <String, dynamic>{};

      if (resp.statusCode == HttpStatus.upgradeRequired) {
        await storage.db.execute(
            "UPDATE _sync_outbox SET status = 'pending' WHERE mutation_id IN ($placeholders)",
            mutationIds);
        return SyncPushResult(
            status: SyncPushStatus.needsUpgrade, errorMessage: respBody);
      }
      if (resp.statusCode == HttpStatus.unauthorized) {
        await storage.db.execute(
            "UPDATE _sync_outbox SET status = 'pending' WHERE mutation_id IN ($placeholders)",
            mutationIds);
        await onAuthExpired?.call();
        return const SyncPushResult(status: SyncPushStatus.unauthorized);
      }
      if (resp.statusCode == HttpStatus.tooManyRequests) {
        final retryHeader = CustomRestPusher.getRetryAfterHeader(resp.headers);
        final nextRetry = CustomRestPusher.parseNextRetryAfter(
            retryHeader, nowMs, backoffPolicy);
        await storage.db.execute(
          "UPDATE _sync_outbox SET status = 'pending', next_retry_at = ? WHERE mutation_id IN ($placeholders)",
          [nextRetry, ...mutationIds],
        );
        return const SyncPushResult(
            status: SyncPushStatus.networkError,
            errorMessage: 'Rate limited (HTTP 429)');
      }
      if (resp.statusCode == HttpStatus.badRequest) {
        final targetStatus = (profile == SyncProfile.basic) ? 'failed' : 'dlq';
        final targets = _extractFailingMutationIds(bodyJson, mutationIds);
        final targetIds = targets.isNotEmpty ? targets : {mutationIds.first};
        for (final targetId in targetIds) {
          await storage.db.execute(
            'UPDATE _sync_outbox SET status = ?, next_retry_at = NULL, error_details_json = ? WHERE mutation_id = ?',
            [targetStatus, respBody, targetId],
          );
        }
        final rem = mutationIds.where((id) => !targetIds.contains(id)).toList();
        if (rem.isNotEmpty) {
          final remPh = List.filled(rem.length, '?').join(', ');
          await storage.db.execute(
              "UPDATE _sync_outbox SET status = 'pending' WHERE mutation_id IN ($remPh)",
              rem);
        }
        return SyncPushResult(
            status: SyncPushStatus.poisonPill, errorMessage: respBody);
      }
      if (resp.statusCode == HttpStatus.conflict) {
        await storage.db.execute(
            "UPDATE _sync_outbox SET status = 'pending' WHERE mutation_id IN ($placeholders)",
            mutationIds);
        return SyncPushResult(
            status: SyncPushStatus.conflict, details: bodyJson);
      }
      if (resp.statusCode == HttpStatus.unprocessableEntity) {
        final targets = _extractFailingMutationIds(bodyJson, mutationIds);
        final targetIds = targets.isNotEmpty ? targets : {mutationIds.first};
        for (final targetId in targetIds) {
          await storage.rollbackOptimistic(targetId,
              status: 'validation_error');
          await storage.db.execute(
            'UPDATE _sync_outbox SET next_retry_at = NULL, error_details_json = ? WHERE mutation_id = ?',
            [respBody, targetId],
          );
        }
        final rem = mutationIds.where((id) => !targetIds.contains(id)).toList();
        if (rem.isNotEmpty) {
          final remPh = List.filled(rem.length, '?').join(', ');
          await storage.db.execute(
              "UPDATE _sync_outbox SET status = 'pending' WHERE mutation_id IN ($remPh)",
              rem);
        }
        return SyncPushResult(
            status: SyncPushStatus.validationError, details: bodyJson);
      }
      if (resp.statusCode == HttpStatus.ok) {
        await storage.db.execute(
            "UPDATE _sync_outbox SET status = 'synced', next_retry_at = NULL, updated_at = ? WHERE mutation_id IN ($placeholders)",
            [nowMs, ...mutationIds]);
        await storage.db.execute('''
          UPDATE _sync_outbox 
          SET status = 'pending', updated_at = ? 
          WHERE status = 'held' 
            AND depends_on_mutation_id IN ($placeholders)
        ''', [nowMs, ...mutationIds]);
        return SyncPushResult(
            status: SyncPushStatus.success, applied: mutations.length);
      }

      throw HttpException('HTTP ${resp.statusCode}: $respBody');
    } catch (e) {
      for (final r in pending) {
        final mutId = r['mutation_id'] as String;
        final currentRetry = (r['retry_count'] as int?) ?? 0;
        final newRetry = currentRetry + 1;
        final targetStatus =
            (newRetry >= backoffPolicy.maxRetries) ? 'dlq' : 'pending';
        final nextRetry = (targetStatus == 'dlq')
            ? null
            : backoffPolicy.nextRetryAt(newRetry, nowMs);
        await storage.db.execute(
          'UPDATE _sync_outbox SET status = ?, retry_count = ?, next_retry_at = ? WHERE mutation_id = ?',
          [targetStatus, newRetry, nextRetry, mutId],
        );
      }
      return SyncPushResult(
          status: SyncPushStatus.networkError, errorMessage: e.toString());
    }
  }
}

Set<String> _extractFailingMutationIds(
    Map<String, dynamic> bodyJson, List<String> batchIds) {
  final result = <String>{};
  void check(dynamic val) {
    if (val is String && batchIds.contains(val)) result.add(val);
  }

  check(bodyJson['mutation_id']);
  check(bodyJson['mutationId']);
  final list =
      bodyJson['errors'] ?? bodyJson['rejected'] ?? bodyJson['failures'];
  if (list is List) {
    for (final item in list) {
      if (item is Map) {
        check(item['mutation_id']);
        check(item['mutationId']);
        check(item['id']);
        if (item['index'] is int) {
          final idx = item['index'] as int;
          if (idx >= 0 && idx < batchIds.length) {
            result.add(batchIds[idx]);
          }
        }
      } else if (item is String) {
        check(item);
      }
    }
  }
  return result;
}
