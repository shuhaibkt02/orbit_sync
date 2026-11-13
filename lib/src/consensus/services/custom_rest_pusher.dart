import 'dart:convert';
import 'dart:io';
import 'package:sqlite3/sqlite3.dart' show Row;
import '../../storage/sync_storage.dart';
import '../../transport/sync_transport.dart';
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
  final int maxConcurrentLanes;
  final Map<String, String? Function(dynamic json)> idExtractors = {};

  CustomRestPusher({
    required this.storage,
    required this.transport,
    required this.profile,
    required this.backoffPolicy,
    this.onAuthExpired,
    this.maxConcurrentLanes = 4,
  });

  void registerIdExtractor(String entity, String? Function(dynamic json) extractor) {
    idExtractors[entity] = extractor;
  }

  Future<SyncPushResult> pushCustomEndpoints({
    required List<Row> pending,
    required List<String> mutationIds,
    required String placeholders,
    required int nowMs,
    int? maxConcurrentLanes,
  }) async {
    final concurrency = maxConcurrentLanes ?? this.maxConcurrentLanes;
    int appliedCount = 0;
    final harvestedIdMap = <String, String>{};
    final processedIds = <String>{};
    SyncPushResult? terminalResult;

    // 1. Group claimed mutations into distinct lanes by entity_name
    final entityLanes = <String, List<Row>>{};
    for (final r in pending) {
      final entity = (r['entity_name'] as String?) ?? 'default';
      entityLanes.putIfAbsent(entity, () => []).add(r);
    }

    // 2. Intra-Entity FIFO: In each lane, mutations must execute in strict chronological sequence_id ASC order
    for (final lane in entityLanes.values) {
      lane.sort((a, b) {
        final seqA = (a['sequence_id'] as int?) ?? (a['created_at'] as int?) ?? 0;
        final seqB = (b['sequence_id'] as int?) ?? (b['created_at'] as int?) ?? 0;
        return seqA.compareTo(seqB);
      });
    }

    final lanes = entityLanes.values.toList();
    if (lanes.isEmpty) {
      return const SyncPushResult(status: SyncPushStatus.success, applied: 0);
    }

    bool hasRateLimited = false;

    Future<void> processLane(List<Row> laneRows) async {
      for (final r in laneRows) {
        if ((terminalResult != null && terminalResult!.status == SyncPushStatus.unauthorized) ||
            hasRateLimited) {
          break;
        }

        final mutationId = r['mutation_id'] as String;

        // DAG Dependency Invariant:
        final parentId = r['depends_on_mutation_id'] as String?;
        if (parentId != null) {
          final parentRows = await storage.db.getAll(
            'SELECT status FROM _sync_outbox WHERE mutation_id = ?',
            [parentId],
          );
          final pStatus = parentRows.isNotEmpty ? (parentRows.first['status'] as String) : null;
          if (pStatus != 'synced') {
            await storage.db.execute(
              "UPDATE _sync_outbox SET status = 'held', updated_at = ? WHERE mutation_id = ?",
              [nowMs, mutationId],
            );
            processedIds.add(mutationId);
            continue;
          }
        }

        final rawUrl = r['endpoint_url'] as String?;
        if (rawUrl == null) {
          await storage.db.execute(
            "UPDATE _sync_outbox SET status = 'failed', error_details_json = '{\"error\":\"Missing endpoint URL\"}' WHERE mutation_id = ?",
            [mutationId],
          );
          processedIds.add(mutationId);
          break;
        }

        final entityId = r['entity_id'] as String;
        final entityName = (r['entity_name'] as String?) ?? 'default';
        final op = r['op'] as String;
        final method = (r['http_method'] as String?) ?? (op == 'delete' ? 'DELETE' : 'POST');
        var targetUrl = rawUrl;
        var payloadJson = r['payload_json'] as String?;

        // Dynamically rewrite any child references harvested from parents in this batch or previous batches
        final allIdMaps = await storage.db.getAll('SELECT local_temp_id, canonical_server_id FROM _sync_id_map');
        final fullIdMap = Map<String, String>.from(harvestedIdMap);
        for (final row in allIdMaps) {
          fullIdMap[row['local_temp_id'] as String] = row['canonical_server_id'] as String;
        }

        for (final entry in fullIdMap.entries) {
          final tempId = entry.key;
          final srvId = entry.value;
          if (targetUrl.contains('/$tempId')) {
            targetUrl = targetUrl.replaceAll('/$tempId', '/$srvId');
          }
          if (payloadJson != null && payloadJson.contains('"$tempId"')) {
            payloadJson = payloadJson.replaceAll('"$tempId"', '"$srvId"');
          }
        }

        if (targetUrl.contains('{id}') || targetUrl.contains(':id') || targetUrl.contains('{parentId}')) {
          if (parentId != null) {
            final parentRows = await storage.db.getAll(
              'SELECT entity_id FROM _sync_outbox WHERE mutation_id = ?',
              [parentId],
            );
            if (parentRows.isNotEmpty) {
              final pEntityId = parentRows.first['entity_id'] as String;
              targetUrl = targetUrl
                  .replaceAll('{id}', pEntityId)
                  .replaceAll(':id', pEntityId)
                  .replaceAll('{parentId}', pEntityId);
            }
          }
        }

        try {
          final payload = payloadJson != null ? (jsonDecode(payloadJson) as Map<String, dynamic>) : null;

          Map<String, String>? customHeaders;
          final rawHeaders = r['headers_json'] as String?;
          if (rawHeaders != null && rawHeaders.isNotEmpty) {
            try {
              final decoded = jsonDecode(rawHeaders);
              if (decoded is Map) {
                customHeaders = decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
              }
            } catch (_) {}
          }

          final mediaPath = (r['media_path'] as String?) ??
              (payload?['media_path'] as String?) ??
              (payload?['mediaPath'] as String?);

          final TransportResponse resp;
          try {
            if (mediaPath != null && mediaPath.isNotEmpty) {
              final uri = Uri.parse(targetUrl);
              final fieldName = (payload?['field_name'] ?? payload?['fieldName'] ?? 'file').toString();
              final fileName = (payload?['file_name'] ?? payload?['fileName'] ?? mediaPath.split(Platform.pathSeparator).last).toString();
              final mimeType = payload?['mime_type']?.toString() ?? payload?['mimeType']?.toString();
              final extraFields = payload != null ? Map<String, dynamic>.from(sanitizePayload(payload)) : null;
              extraFields?.remove('field_name');
              extraFields?.remove('fieldName');
              extraFields?.remove('file_name');
              extraFields?.remove('fileName');
              extraFields?.remove('mime_type');
              extraFields?.remove('mimeType');
              extraFields?.remove('media_path');
              extraFields?.remove('mediaPath');

              resp = await transport.pushMultipart(
                uri: uri,
                method: method,
                fieldName: fieldName,
                filePath: mediaPath,
                fileName: fileName,
                mimeType: mimeType,
                extraFields: extraFields?.isNotEmpty == true ? extraFields : null,
                headers: customHeaders,
              );
            } else {
              resp = await transport.pushCustom(
                url: targetUrl,
                method: method,
                mutationId: mutationId,
                createdAtMs: r['created_at'] as int,
                payload: payload,
                entityId: entityId,
                headers: customHeaders,
              );
            }
          } catch (e) {
            processedIds.add(mutationId);
            await recordFailure(r, mutationId, nowMs, errorMsg: e.toString());
            terminalResult ??= SyncPushResult(status: SyncPushStatus.networkError, errorMessage: e.toString());
            break;
          }

          if (resp.error != null) {
            final err = resp.error is Exception ? resp.error as Exception : Exception(resp.error.toString());
            processedIds.add(mutationId);
            await recordFailure(r, mutationId, nowMs, errorMsg: err.toString());
            terminalResult ??= SyncPushResult(status: SyncPushStatus.networkError, errorMessage: err.toString());
            break;
          }

          if (resp.statusCode >= 200 && resp.statusCode < 300) {
            await storage.db.writeTransaction((tx) async {
              if ((method == 'POST' || method == 'PUT') && resp.body.isNotEmpty) {
                try {
                  final decoded = jsonDecode(resp.body);
                  if (decoded is Map) {
                    final extractor = idExtractors[entityName];
                    final extracted = extractor?.call(decoded);
                    final remoteId = (extracted ??
                        decoded['id'] ??
                        decoded['_id'] ??
                        (decoded['data'] is Map ? (decoded['data']['id'] ?? decoded['data']['_id']) : null))?.toString();
                    if (remoteId != null && remoteId.isNotEmpty) {
                      harvestedIdMap[entityId] = remoteId;
                      if (remoteId != entityId) {
                        await tx.execute('''
                          INSERT OR REPLACE INTO _sync_id_map (entity_name, local_temp_id, canonical_server_id, created_at)
                          VALUES (?, ?, ?, ?)
                        ''', [entityName, entityId, remoteId, nowMs]);

                        try {
                          await tx.execute(
                            'UPDATE "$entityName" SET id = ? WHERE id = ?',
                            [remoteId, entityId],
                          );
                        } catch (_) {}

                        await tx.execute(
                          "UPDATE _sync_outbox SET entity_id = ? WHERE entity_id = ? AND entity_name = ?",
                          [remoteId, entityId, entityName],
                        );
                        await tx.execute(
                          "UPDATE _sync_outbox SET endpoint_url = REPLACE(endpoint_url, ?, ?) WHERE endpoint_url LIKE ?",
                          ['/$entityId', '/$remoteId', '%/$entityId%'],
                        );
                        await tx.execute(
                          "UPDATE _sync_outbox SET payload_json = REPLACE(payload_json, ?, ?) WHERE payload_json LIKE ?",
                          ['"$entityId"', '"$remoteId"', '%"$entityId"%'],
                        );

                        try {
                          await tx.execute(
                            'UPDATE "$entityName" SET data_json = REPLACE(data_json, ?, ?) WHERE data_json LIKE ?',
                            ['"$entityId"', '"$remoteId"', '%"$entityId"%'],
                          );
                        } catch (_) {}
                      }

                      // Update dependent children endpoint_url and payload_json
                      await tx.execute('''
                        UPDATE _sync_outbox 
                        SET endpoint_url = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(endpoint_url, '{id}', ?), ':id', ?), '{parentId}', ?), ':parentId', ?), ?, ?),
                            payload_json = REPLACE(payload_json, ?, ?)
                        WHERE depends_on_mutation_id = ?
                      ''', [
                        remoteId,
                        remoteId,
                        remoteId,
                        remoteId,
                        '/$entityId',
                        '/$remoteId',
                        '"$entityId"',
                        '"$remoteId"',
                        mutationId,
                      ]);
                    }
                  }
                } catch (_) {}
              }

              if (op == 'delete') {
                try {
                  await tx.execute('DELETE FROM "$entityName" WHERE id = ?', [entityId]);
                } catch (_) {}
              }

              await tx.execute(
                "UPDATE _sync_outbox SET status = 'synced', next_retry_at = NULL, updated_at = ? WHERE mutation_id = ?",
                [nowMs, mutationId],
              );
              await tx.execute('''
                UPDATE _sync_outbox 
                SET status = 'pending', updated_at = ? 
                WHERE status = 'held' 
                  AND depends_on_mutation_id = ?
              ''', [nowMs, mutationId]);
            });

            appliedCount++;
            processedIds.add(mutationId);
          } else if (resp.statusCode == HttpStatus.unauthorized) {
            processedIds.add(mutationId);
            await storage.db.execute(
              "UPDATE _sync_outbox SET status = 'pending' WHERE mutation_id IN ($placeholders) AND status = 'in_flight'",
              mutationIds,
            );
            await onAuthExpired?.call();
            terminalResult = const SyncPushResult(status: SyncPushStatus.unauthorized);
            break;
          } else if (resp.statusCode == HttpStatus.tooManyRequests) {
            processedIds.add(mutationId);
            final retryHeader = getRetryAfterHeader(resp.headers);
            final nextRetry = parseNextRetryAfter(retryHeader, nowMs, backoffPolicy);
            await storage.db.execute(
              "UPDATE _sync_outbox SET status = 'pending', next_retry_at = ? WHERE mutation_id = ?",
              [nextRetry, mutationId],
            );
            terminalResult ??= const SyncPushResult(status: SyncPushStatus.networkError, errorMessage: 'Rate limited (HTTP 429)');
            hasRateLimited = true;
            break;
          } else if (resp.statusCode == HttpStatus.badRequest) {
            final targetStatus = (profile == SyncProfile.basic) ? 'failed' : 'dlq';
            await storage.db.execute(
              'UPDATE _sync_outbox SET status = ?, next_retry_at = NULL, error_details_json = ? WHERE mutation_id = ?',
              [targetStatus, resp.body, mutationId],
            );
            processedIds.add(mutationId);
            break;
          } else if (resp.statusCode == HttpStatus.conflict) {
            processedIds.add(mutationId);
            await storage.db.execute(
              'UPDATE _sync_outbox SET status = ?, next_retry_at = NULL, error_details_json = ? WHERE mutation_id = ?',
              ['conflict', resp.body, mutationId],
            );
            terminalResult ??= SyncPushResult(status: SyncPushStatus.conflict, errorMessage: resp.body);
            break;
          } else if (resp.statusCode == HttpStatus.unprocessableEntity) {
            await storage.rollbackOptimistic(mutationId, status: 'validation_error');
            await storage.db.execute(
              'UPDATE _sync_outbox SET next_retry_at = NULL, error_details_json = ? WHERE mutation_id = ?',
              [resp.body, mutationId],
            );
            terminalResult ??= SyncPushResult(status: SyncPushStatus.validationError, errorMessage: resp.body);
            processedIds.add(mutationId);
            break;
          } else {
            final errorBody = resp.body.isNotEmpty ? resp.body : 'HTTP ${resp.statusCode}';
            await recordFailure(r, mutationId, nowMs, errorMsg: errorBody);
            processedIds.add(mutationId);
            break;
          }
        } catch (e) {
          processedIds.add(mutationId);
          await recordFailure(r, mutationId, nowMs, errorMsg: e.toString());
          terminalResult ??= SyncPushResult(status: SyncPushStatus.networkError, errorMessage: e.toString());
          break;
        }
      }
    }

    try {
      // 3. Cross-Entity Parallelism across asynchronous worker pool
      final poolLimit = concurrency > 0 ? concurrency : 4;
      final workerCount = lanes.length < poolLimit ? lanes.length : poolLimit;
      int nextLaneIndex = 0;

      Future<void> laneWorker() async {
        while (true) {
          if ((terminalResult != null && terminalResult!.status == SyncPushStatus.unauthorized) ||
              hasRateLimited) {
            break;
          }
          final idx = nextLaneIndex++;
          if (idx >= lanes.length) break;
          await processLane(lanes[idx]);
        }
      }

      final workers = List.generate(workerCount, (_) => laneWorker());
      await Future.wait(workers);

      if (terminalResult != null && terminalResult!.status == SyncPushStatus.unauthorized) {
        return terminalResult!;
      }
      if (appliedCount > 0) {
        return SyncPushResult(status: SyncPushStatus.success, applied: appliedCount, errorMessage: terminalResult?.errorMessage);
      }
      if (terminalResult != null) {
        return terminalResult!;
      }
      return SyncPushResult(status: SyncPushStatus.success, applied: 0);
    } finally {
      final unhandled = mutationIds.where((id) => !processedIds.contains(id)).toList();
      if (unhandled.isNotEmpty) {
        final ph = List.filled(unhandled.length, '?').join(', ');
        await storage.db.execute(
          "UPDATE _sync_outbox SET status = 'pending' WHERE mutation_id IN ($ph) AND status = 'in_flight'",
          unhandled,
        );
      }
    }
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

  static String? getRetryAfterHeader(Map<String, String> headers) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'retry-after') return entry.value;
    }
    return null;
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
