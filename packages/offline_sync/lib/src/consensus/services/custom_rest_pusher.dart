import 'dart:convert';
import 'dart:io';
import 'package:sqlite3/sqlite3.dart' show Row;
import '../../storage/sync_storage.dart';
import '../../sync_transport.dart';
import '../../sync_profile.dart';
import '../domain/models/sync_result.dart';
import '../domain/policies/backoff_policy.dart';

/// Dispatches mutations to developer-configured REST endpoints (Mode 1: 1-by-1 CRUD).
class CustomRestPusher {
  final SyncStorage storage;
  final SyncTransport transport;
  final SyncProfile profile;
  final BackoffPolicy backoffPolicy;
  final Future<void> Function()? onAuthExpired;

  CustomRestPusher({
    required this.storage,
    required this.transport,
    required this.profile,
    required this.backoffPolicy,
    this.onAuthExpired,
  });

  Future<SyncPushResult> pushCustomEndpoints({
    required List<Row> pending,
    required List<String> mutationIds,
    required String placeholders,
    required int nowMs,
  }) async {
    int appliedCount = 0;
    for (final r in pending) {
      final mutationId = r['mutation_id'] as String;
      final rawUrl = r['endpoint_url'] as String?;
      if (rawUrl == null) continue;

      final entityId = r['entity_id'] as String;
      final op = r['op'] as String;
      final method = (r['http_method'] as String?) ?? (op == 'delete' ? 'DELETE' : 'POST');
      var targetUrl = rawUrl;
      if ((method == 'PUT' || method == 'PATCH' || method == 'DELETE') && !targetUrl.endsWith('/$entityId')) {
        targetUrl = '$targetUrl/$entityId';
      }

      try {
        final payloadJson = r['payload_json'] as String?;
        final payload = payloadJson != null ? (jsonDecode(payloadJson) as Map<String, dynamic>) : null;

        final resp = await transport.pushCustom(
          url: targetUrl,
          method: method,
          mutationId: mutationId,
          createdAtMs: r['created_at'] as int,
          payload: payload,
          entityId: entityId,
        );
        if (resp.error != null) {
          throw resp.error is Exception ? resp.error as Exception : Exception(resp.error.toString());
        }

        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          await storage.db.execute(
            "UPDATE _sync_outbox SET status = 'synced', next_retry_at = NULL WHERE mutation_id = ?",
            [mutationId],
          );
          appliedCount++;
        } else if (resp.statusCode == HttpStatus.unauthorized) {
          await storage.db.execute(
            "UPDATE _sync_outbox SET status = 'pending' WHERE mutation_id IN ($placeholders) AND status = 'in_flight'",
            mutationIds,
          );
          await onAuthExpired?.call();
          return const SyncPushResult(status: SyncPushStatus.unauthorized);
        } else if (resp.statusCode == HttpStatus.tooManyRequests) {
          final nextRetry = parseNextRetryAfter(resp.headers['retry-after'], nowMs, backoffPolicy);
          await storage.db.execute(
            "UPDATE _sync_outbox SET status = 'pending', next_retry_at = ? WHERE mutation_id = ?",
            [nextRetry, mutationId],
          );
          return const SyncPushResult(status: SyncPushStatus.networkError, errorMessage: 'Rate limited (HTTP 429)');
        } else if (resp.statusCode == HttpStatus.badRequest) {
          final targetStatus = (profile == SyncProfile.basic) ? 'failed' : 'dlq';
          await storage.db.execute(
            'UPDATE _sync_outbox SET status = ?, next_retry_at = NULL, error_details_json = ? WHERE mutation_id = ?',
            [targetStatus, resp.body, mutationId],
          );
        } else if (resp.statusCode == HttpStatus.conflict) {
          await storage.db.execute(
            'UPDATE _sync_outbox SET status = ?, next_retry_at = NULL, error_details_json = ? WHERE mutation_id = ?',
            ['conflict', resp.body, mutationId],
          );
          return SyncPushResult(status: SyncPushStatus.conflict, errorMessage: resp.body);
        } else if (resp.statusCode == HttpStatus.unprocessableEntity) {
          await storage.rollbackOptimistic(mutationId, status: 'validation_error');
          await storage.db.execute(
            'UPDATE _sync_outbox SET next_retry_at = NULL, error_details_json = ? WHERE mutation_id = ?',
            [resp.body, mutationId],
          );
        } else {
          await recordFailure(r, mutationId, nowMs);
        }
      } catch (e) {
        await recordFailure(r, mutationId, nowMs, errorMsg: e.toString());
        return SyncPushResult(status: SyncPushStatus.networkError, errorMessage: e.toString());
      }
    }
    return SyncPushResult(status: SyncPushStatus.success, applied: appliedCount);
  }

  Future<void> recordFailure(Row r, String mutId, int nowMs, {String? errorMsg}) async {
    final currentRetry = (r['retry_count'] as int?) ?? 0;
    final newRetry = currentRetry + 1;
    final targetStatus = (newRetry >= backoffPolicy.maxRetries) ? 'dlq' : 'pending';
    final nextRetry = (targetStatus == 'dlq') ? null : backoffPolicy.nextRetryAt(newRetry, nowMs);
    await storage.db.execute(
      'UPDATE _sync_outbox SET status = ?, retry_count = ?, next_retry_at = ?, error_details_json = ? WHERE mutation_id = ?',
      [targetStatus, newRetry, nextRetry, errorMsg ?? 'Server error', mutId],
    );
  }

  static int parseNextRetryAfter(
    String? header,
    int nowMs,
    BackoffPolicy policy, {
    RetryAfterParser? parser,
    bool withJitter = true,
  }) {
    final retryParser = parser ?? RetryAfterParser();
    return retryParser.parseNextRetryAt(
      header,
      nowMs,
      fallbackDelay: policy.delayFor(1),
      withJitter: withJitter,
    );
  }
}
