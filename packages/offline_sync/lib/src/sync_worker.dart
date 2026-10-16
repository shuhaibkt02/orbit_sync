import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:sqlite3/sqlite3.dart' show Row;
import 'package:sqlite_async/sqlite_async.dart' show SqliteWriteContext;
import 'sync_storage.dart';
import 'sync_profile.dart';

enum SyncPushStatus { success, networkError, conflict, validationError, poisonPill, unauthorized, needsUpgrade }
enum SyncPullStatus { success, networkError, expiredCursor, unauthorized }

typedef MutationMigrator = Map<String, dynamic> Function(
  int fromVersion,
  int toVersion,
  String entity,
  Map<String, dynamic> payload,
);

class SyncPushResult {
  final SyncPushStatus status;
  final int applied;
  final String? errorMessage;
  final Map<String, dynamic>? details;

  const SyncPushResult({
    required this.status,
    this.applied = 0,
    this.errorMessage,
    this.details,
  });
}

class SyncPullResult {
  final SyncPullStatus status;
  final int changeCount;
  final int nextCursor;
  final bool hasMore;
  final String? errorMessage;

  const SyncPullResult({
    required this.status,
    this.changeCount = 0,
    this.nextCursor = 0,
    this.hasMore = false,
    this.errorMessage,
  });
}

/// Bidirectional sync worker handling push queue, 3-way merge, invariant validation,
/// and generation-swap resync.
class SyncWorker {
  final SyncStorage storage;
  final String serverUrl;
  final HttpClient httpClient;
  final SyncProfile profile;
  final int pullPageLimit;
  final Map<String, dynamic>? scopeFilter;
  Future<String?> Function()? getAuthToken;
  Future<void> Function()? onAuthExpired;
  Future<void>? _refreshFuture;

  Future<void> _handleAuthExpired() async {
    if (onAuthExpired == null) return;
    if (_refreshFuture != null) {
      await _refreshFuture;
      return;
    }
    _refreshFuture = onAuthExpired!();
    try {
      await _refreshFuture;
    } finally {
      _refreshFuture = null;
    }
  }

  /// Business invariant validator across co-dependent fields.
  /// Returns null if valid, or an RFC 9457 error message string if invalid.
  String? Function(String entity, Map<String, dynamic> mergedRecord)? validateInvariants;

  /// Current application schema version and lazy upcast migrator
  int currentSchemaVersion;
  MutationMigrator? migrator;
  final void Function(String message)? onLog;

  SyncWorker({
    required this.storage,
    required this.serverUrl,
    this.profile = SyncProfile.enterprise,
    HttpClient? client,
    this.pullPageLimit = 50,
    this.scopeFilter,
    this.getAuthToken,
    this.onAuthExpired,
    this.validateInvariants,
    this.currentSchemaVersion = 1,
    this.migrator,
    this.onLog,
  }) : httpClient = client ?? HttpClient();

  /// Gets the last checkpointed cursor from metadata.
  Future<int> getLastSyncedCursor() async {
    final rows = await storage.db.getAll(
      'SELECT value FROM _sync_metadata WHERE key = ?',
      ['last_synced_cursor'],
    );
    if (rows.isEmpty || rows.first['value'] == null) return 0;
    return int.tryParse(rows.first['value'] as String) ?? 0;
  }

  /// Sets the checkpointed cursor in metadata.
  Future<void> setLastSyncedCursor(int cursor) async {
    await storage.db.execute(
      'INSERT OR REPLACE INTO _sync_metadata (key, value) VALUES (?, ?)',
      ['last_synced_cursor', cursor.toString()],
    );
  }

  /// Drains up to [batchSize] pending outbox mutations to POST /sync/push.
  /// Enforces DAG dependencies: selectively holds children if their parent is quarantined in DLQ/conflict.
  Future<SyncPushResult> pushBatch({int batchSize = 10, String? chaos}) async {
    // 0. Automatically unblock any held mutations whose parent has successfully synced
    if (profile == SyncProfile.enterprise) {
      await storage.db.execute('''
        UPDATE _sync_outbox 
        SET status = 'pending' 
        WHERE status = 'held' 
          AND depends_on_mutation_id IN (SELECT mutation_id FROM _sync_outbox WHERE status = 'synced');
      ''');
    }

    // 1. Fetch pending candidates
    final pendingRaw = await storage.db.getAll(
      "SELECT * FROM _sync_outbox WHERE status = 'pending' ORDER BY created_at ASC LIMIT ?",
      [batchSize * 2],
    );

    if (pendingRaw.isEmpty) {
      return const SyncPushResult(status: SyncPushStatus.success, applied: 0);
    }

    // 2. Selective holding (Enterprise only): filter out mutations whose parent is quarantined (dlq/conflict/held)
    final pending = <Row>[];
    for (final r in pendingRaw) {
      if (profile == SyncProfile.enterprise) {
        final parentId = r['depends_on_mutation_id'] as String?;
        if (parentId != null) {
          final parentRows = await storage.db.getAll(
            'SELECT status FROM _sync_outbox WHERE mutation_id = ?',
            [parentId],
          );
          if (parentRows.isNotEmpty) {
            final pStatus = parentRows.first['status'] as String;
            if (pStatus == 'dlq' || pStatus == 'conflict' || pStatus == 'held') {
              await storage.db.execute(
                "UPDATE _sync_outbox SET status = 'held' WHERE mutation_id = ?",
                [r['mutation_id']],
              );
              continue;
            }
          }
        }
      }
      pending.add(r);
      if (pending.length == batchSize) break;
    }

    if (pending.isEmpty) {
      return const SyncPushResult(status: SyncPushStatus.success, applied: 0);
    }

    final mutationIds = pending.map((r) => r['mutation_id'] as String).toList();

    // Mark as in_flight
    final placeholders = List.filled(mutationIds.length, '?').join(', ');
    await storage.db.execute(
      "UPDATE _sync_outbox SET status = 'in_flight' WHERE mutation_id IN ($placeholders)",
      mutationIds,
    );

    final mutations = <Map<String, dynamic>>[];
    for (final r in pending) {
      final fromVersion = (r['schema_version'] as int?) ?? 1;
      final payloadJson = r['payload_json'] as String?;
      var payload = payloadJson != null ? (jsonDecode(payloadJson) as Map<String, dynamic>) : <String, dynamic>{};
      var targetVersion = fromVersion;

      if (fromVersion < currentSchemaVersion && migrator != null) {
        payload = migrator!(fromVersion, currentSchemaVersion, r['entity_name'] as String, payload);
        targetVersion = currentSchemaVersion;

        await storage.db.execute('''
          UPDATE _sync_outbox 
          SET payload_json = ?, schema_version = ? 
          WHERE mutation_id = ?
        ''', [jsonEncode(payload), currentSchemaVersion, r['mutation_id']]);
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

    final hasCustomEndpoints = pending.any((r) => r['endpoint_url'] != null);
    if (hasCustomEndpoints) {
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
          final req = await httpClient.openUrl(method, Uri.parse(targetUrl));
          req.headers.contentType = ContentType.json;
          req.headers.set('Idempotency-Key', mutationId);
          req.headers.set('X-Client-Mutation-Id', mutationId);
          req.headers.set('X-Offline-Sync', 'true');
          final createdAtIso = DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int).toUtc().toIso8601String();
          req.headers.set('X-Offline-Created-At', createdAtIso);

          if (getAuthToken != null) {
            final token = await getAuthToken!();
            if (token != null) req.headers.set('Authorization', 'Bearer $token');
          }

          if (method != 'DELETE') {
            final payloadJson = r['payload_json'] as String?;
            var payload = payloadJson != null ? (jsonDecode(payloadJson) as Map<String, dynamic>) : <String, dynamic>{};
            final bodyMap = Map<String, dynamic>.from(payload);
            bodyMap['_offline_meta'] = {
              'is_offline': true,
              'offline_created_at': createdAtIso,
              'mutation_id': mutationId,
            };
            req.add(utf8.encode(jsonEncode(bodyMap)));
          }

          final resp = await req.close();
          final respBody = await utf8.decoder.bind(resp).join();

          if (resp.statusCode >= 200 && resp.statusCode < 300) {
            await storage.db.execute(
              "UPDATE _sync_outbox SET status = 'synced' WHERE mutation_id = ?",
              [mutationId],
            );
            onLog?.call('Orbit: Successfully synced mutation $mutationId to $targetUrl (HTTP ${resp.statusCode})');
            appliedCount++;
          } else if (resp.statusCode == HttpStatus.unauthorized) {
            await storage.db.execute(
              "UPDATE _sync_outbox SET status = 'pending' WHERE mutation_id IN ($placeholders) AND status = 'in_flight'",
              mutationIds,
            );
            await _handleAuthExpired();
            return const SyncPushResult(status: SyncPushStatus.unauthorized);
          } else if (resp.statusCode == HttpStatus.tooManyRequests) {
            final retryAfter = resp.headers.value('retry-after') ?? '30';
            await storage.db.execute(
              "UPDATE _sync_outbox SET status = 'pending' WHERE mutation_id IN ($placeholders) AND status = 'in_flight'",
              mutationIds,
            );
            onLog?.call('Orbit: Rate limited (HTTP 429). Pausing queue. Retry-After: $retryAfter seconds.');
            return SyncPushResult(
              status: SyncPushStatus.networkError,
              errorMessage: 'Rate limited (HTTP 429). Retry-After: $retryAfter',
            );
          } else if (resp.statusCode >= 500) {
            await storage.db.execute(
              "UPDATE _sync_outbox SET status = 'pending', retry_count = retry_count + 1 WHERE mutation_id IN ($placeholders) AND status = 'in_flight'",
              mutationIds,
            );
            onLog?.call('Orbit: Transient server error (HTTP ${resp.statusCode}) for $targetUrl. Remains pending.');
            return SyncPushResult(
              status: SyncPushStatus.networkError,
              errorMessage: 'Server error (HTTP ${resp.statusCode}): $respBody',
            );
          } else if (resp.statusCode == HttpStatus.badRequest) {
            final targetStatus = (profile == SyncProfile.basic) ? 'failed' : 'dlq';
            final structuredError = jsonEncode({
              'statusCode': resp.statusCode,
              'error': respBody,
              'url': targetUrl,
              'failedAt': DateTime.now().toUtc().toIso8601String(),
            });
            await storage.db.execute('''
              UPDATE _sync_outbox SET status = ?, error_details_json = ? WHERE mutation_id = ?
            ''', [targetStatus, structuredError, mutationId]);
            onLog?.call('Orbit: Poison pill error (HTTP 400). Quarantined mutation to DLQ: $respBody');
          } else if (resp.statusCode == HttpStatus.unprocessableEntity) {
            final structuredError = jsonEncode({
              'statusCode': resp.statusCode,
              'error': respBody,
              'url': targetUrl,
              'failedAt': DateTime.now().toUtc().toIso8601String(),
            });
            await storage.rollbackOptimistic(mutationId, status: 'validation_error');
            await storage.db.execute(
              'UPDATE _sync_outbox SET error_details_json = ? WHERE mutation_id = ?',
              [structuredError, mutationId],
            );
            onLog?.call('Orbit: Validation error (HTTP 422). Rolled back active row: $respBody');
          } else if (resp.statusCode >= 400) {
            final structuredError = jsonEncode({
              'statusCode': resp.statusCode,
              'error': respBody,
              'url': targetUrl,
              'failedAt': DateTime.now().toUtc().toIso8601String(),
            });
            await storage.db.execute('''
              UPDATE _sync_outbox SET status = 'failed', error_details_json = ? WHERE mutation_id = ?
            ''', [structuredError, mutationId]);
            onLog?.call('Orbit: Server error (HTTP ${resp.statusCode}) for $targetUrl: $respBody');
          } else {
            await storage.db.execute(
              "UPDATE _sync_outbox SET status = 'pending' WHERE mutation_id = ?",
              [mutationId],
            );
          }
        } catch (e) {
          await storage.db.execute(
            "UPDATE _sync_outbox SET status = 'pending', retry_count = retry_count + 1 WHERE mutation_id IN ($placeholders) AND status = 'in_flight'",
            mutationIds,
          );
          onLog?.call('Orbit: Network or push error for $targetUrl: $e');
          return SyncPushResult(status: SyncPushStatus.networkError, errorMessage: e.toString());
        }
      }
      return SyncPushResult(status: SyncPushStatus.success, applied: appliedCount);
    }

    final idempotencyKey = mutationIds.length == 1 ? mutationIds.first : 'batch-${mutationIds.first}';

    try {
      final uriStr = '$serverUrl/sync/push${chaos != null ? '?chaos=$chaos' : ''}';
      final req = await httpClient.openUrl('POST', Uri.parse(uriStr));
      req.headers.contentType = ContentType.json;
      req.headers.set('Idempotency-Key', idempotencyKey);

      if (getAuthToken != null) {
        final token = await getAuthToken!();
        if (token != null) req.headers.set('Authorization', 'Bearer $token');
      }

      req.add(utf8.encode(jsonEncode(mutations)));
      final resp = await req.close();
      final respBody = await utf8.decoder.bind(resp).join();
      final bodyJson = respBody.isNotEmpty ? (jsonDecode(respBody) as Map<String, dynamic>) : <String, dynamic>{};

      if (resp.statusCode == HttpStatus.upgradeRequired) {
        // Client schema is below server minimum floor; pause queue without burning retry count
        await storage.db.execute(
          "UPDATE _sync_outbox SET status = 'pending' WHERE mutation_id IN ($placeholders)",
          mutationIds,
        );
        return SyncPushResult(status: SyncPushStatus.needsUpgrade, errorMessage: respBody);
      }

      if (resp.statusCode == HttpStatus.unauthorized) {
        await storage.db.execute(
          "UPDATE _sync_outbox SET status = 'pending' WHERE mutation_id IN ($placeholders)",
          mutationIds,
        );
        await _handleAuthExpired();
        return const SyncPushResult(status: SyncPushStatus.unauthorized);
      }

      if (resp.statusCode == HttpStatus.tooManyRequests) {
        final retryAfter = resp.headers.value('retry-after') ?? '30';
        await storage.db.execute(
          "UPDATE _sync_outbox SET status = 'pending' WHERE mutation_id IN ($placeholders)",
          mutationIds,
        );
        onLog?.call('Orbit: Rate limited (HTTP 429). Pausing batch. Retry-After: $retryAfter seconds.');
        return SyncPushResult(
          status: SyncPushStatus.networkError,
          errorMessage: 'Rate limited (HTTP 429). Retry-After: $retryAfter',
        );
      }

      if (resp.statusCode >= 500) {
        await storage.db.execute(
          "UPDATE _sync_outbox SET status = 'pending', retry_count = retry_count + 1 WHERE mutation_id IN ($placeholders)",
          mutationIds,
        );
        onLog?.call('Orbit: Transient server error (HTTP ${resp.statusCode}). Remains pending.');
        return SyncPushResult(
          status: SyncPushStatus.networkError,
          errorMessage: 'Server error (HTTP ${resp.statusCode}): $respBody',
        );
      }

      if (resp.statusCode == HttpStatus.badRequest) {
        final targetStatus = (profile == SyncProfile.basic) ? 'failed' : 'dlq';
        await storage.db.execute('''
          UPDATE _sync_outbox 
          SET status = ?, error_details_json = ? 
          WHERE mutation_id = ?
        ''', [targetStatus, respBody, mutationIds.first]);

        if (mutationIds.length > 1) {
          final remaining = mutationIds.sublist(1);
          final remPlaceholders = List.filled(remaining.length, '?').join(', ');
          await storage.db.execute(
            "UPDATE _sync_outbox SET status = 'pending' WHERE mutation_id IN ($remPlaceholders)",
            remaining,
          );
        }
        onLog?.call('Orbit: Poison pill error (HTTP 400). Quarantined mutation to DLQ: $respBody');
        return SyncPushResult(status: SyncPushStatus.poisonPill, errorMessage: respBody);
      }

      if (resp.statusCode == HttpStatus.conflict) {
        onLog?.call('Orbit: Conflict detected (HTTP 409): $respBody');
        return SyncPushResult(status: SyncPushStatus.conflict, details: bodyJson);
      }

      if (resp.statusCode == HttpStatus.unprocessableEntity) {
        // Rollback optimistic active row to base snapshot; preserve draft in outbox
        await storage.rollbackOptimistic(mutationIds.first, status: 'validation_error');
        await storage.db.execute(
          'UPDATE _sync_outbox SET error_details_json = ? WHERE mutation_id = ?',
          [respBody, mutationIds.first],
        );
        onLog?.call('Orbit: Validation error (HTTP 422). Rolled back active row: $respBody');
        return SyncPushResult(status: SyncPushStatus.validationError, details: bodyJson);
      }

      if (resp.statusCode == HttpStatus.ok) {
        await storage.db.execute(
          "UPDATE _sync_outbox SET status = 'synced' WHERE mutation_id IN ($placeholders)",
          mutationIds,
        );
        onLog?.call('Orbit: Successfully pushed ${mutations.length} mutation(s).');
        return SyncPushResult(status: SyncPushStatus.success, applied: mutations.length);
      }

      throw HttpException('HTTP ${resp.statusCode}: $respBody');
    } catch (e) {
      await storage.db.execute(
        "UPDATE _sync_outbox SET status = 'pending' WHERE mutation_id IN ($placeholders)",
        mutationIds,
      );
      onLog?.call('Orbit: Network or push error: $e');
      return SyncPushResult(status: SyncPushStatus.networkError, errorMessage: e.toString());
    }
  }

  /// Pulls a single page of changes from GET /sync/pull.
  /// Handles 3-way merging, invariant validation, and tombstone/scope eviction.
  Future<SyncPullResult> pullPage({String? chaos}) async {
    final since = await getLastSyncedCursor();
    var uriStr = '$serverUrl/sync/pull?since=$since&limit=$pullPageLimit';
    if (chaos != null) uriStr += '&chaos=$chaos';
    if (scopeFilter != null) {
      uriStr += '&scope=${Uri.encodeComponent(jsonEncode(scopeFilter))}';
    }

    try {
      final req = await httpClient.openUrl('GET', Uri.parse(uriStr));
      if (getAuthToken != null) {
        final token = await getAuthToken!();
        if (token != null) req.headers.set('Authorization', 'Bearer $token');
      }

      final resp = await req.close();
      if (resp.statusCode == HttpStatus.gone) {
        return const SyncPullResult(status: SyncPullStatus.expiredCursor);
      }
      if (resp.statusCode == HttpStatus.unauthorized) {
        return const SyncPullResult(status: SyncPullStatus.unauthorized);
      }

      final respBody = await utf8.decoder.bind(resp).join();
      final bodyJson = jsonDecode(respBody) as Map<String, dynamic>;
      final changes = (bodyJson['changes'] as List).cast<Map<String, dynamic>>();
      final nextCursor = bodyJson['next_cursor'] as int;
      final hasMore = bodyJson['has_more'] as bool;

      await storage.db.writeTransaction((tx) async {
        for (final change in changes) {
          final entity = change['entity'] as String;
          final id = change['id'].toString();
          final isDeleted = change['_deleted'] == true;
          final isLeftScope = change['left_scope'] == true;

          if (isDeleted || isLeftScope) {
            await tx.execute('DELETE FROM $entity WHERE id = ?', [id]);
            final pendingRows = await tx.getAll(
              "SELECT * FROM _sync_outbox WHERE entity_name = ? AND entity_id = ? AND status = 'pending'",
              [entity, id],
            );
            if (pendingRows.isNotEmpty) {
              await tx.execute('''
                UPDATE _sync_outbox 
                SET status = 'conflict', error_details_json = ? 
                WHERE entity_name = ? AND entity_id = ? AND status = 'pending'
              ''', [
                jsonEncode({
                  'type': 'https://offline-sync.dev/errors/delete-conflict',
                  'title': 'Update vs Delete Conflict',
                  'detail': 'Record was deleted on the server while modified offline locally.',
                }),
                entity,
                id,
              ]);
            }
            continue;
          }

          final remoteData = (change['data'] as Map<String, dynamic>?) ?? {};
          final version = (change['version'] as int?) ?? 1;
          final now = DateTime.now().millisecondsSinceEpoch;

          // Check if there are pending local mutations for this record
          final pendingRows = await tx.getAll(
            "SELECT * FROM _sync_outbox WHERE entity_name = ? AND entity_id = ? AND status = 'pending' ORDER BY created_at ASC",
            [entity, id],
          );

          if (pendingRows.isEmpty) {
            // No local conflict: directly write remote data
            await _upsertRow(tx, entity, id, remoteData, version, now, null);
          } else if (pendingRows.first['op'] == 'delete') {
            // Delete vs Update conflict: client deleted locally, remote updated.
            // Do not resurrect into active table.
            if (profile != SyncProfile.basic) {
              await tx.execute('''
                UPDATE _sync_outbox 
                SET status = 'conflict', error_details_json = ? 
                WHERE mutation_id = ?
              ''', [
                jsonEncode({
                  'type': 'https://offline-sync.dev/errors/delete-vs-update',
                  'title': 'Delete vs Update Conflict',
                  'detail': 'Record was deleted locally while modified remotely on the server.',
                }),
                pendingRows.first['mutation_id'],
              ]);
            }
            continue;
          } else if (profile == SyncProfile.basic) {
            // Last-Write-Wins (LWW): Remote state overwrites local table; outbox mutation marked conflict
            await _upsertRow(tx, entity, id, remoteData, version, now, null);
            await tx.execute('''
              UPDATE _sync_outbox 
              SET status = 'conflict', error_details_json = ? 
              WHERE entity_name = ? AND entity_id = ? AND status = 'pending'
            ''', [
              jsonEncode({'title': 'Overwritten by LWW remote change'}),
              entity,
              id,
            ]);
          } else {
            // Standard & Enterprise: 3-way field merge
            final pendingMut = pendingRows.first;
            final mutId = pendingMut['mutation_id'] as String;
            final baseJson = pendingMut['base_snapshot_json'] as String?;
            final baseMap = baseJson != null ? (jsonDecode(baseJson) as Map<String, dynamic>) : <String, dynamic>{};
            final localJson = pendingMut['payload_json'] as String?;
            final localMap = localJson != null ? (jsonDecode(localJson) as Map<String, dynamic>) : <String, dynamic>{};

            // 3-way merge
            // ponytail: column-level merge with remote precedence on identical field collisions; upgrade to CRDT only if character-level text diffing is needed.
            final merged = Map<String, dynamic>.from(remoteData);
            for (final key in localMap.keys) {
              if (localMap[key] != baseMap[key]) {
                // Local made a change to this key
                merged[key] = localMap[key];
              }
            }

            // Invariant validation
            if (validateInvariants != null) {
              final invariantError = validateInvariants!(entity, merged);
              if (invariantError != null) {
                // Co-dependent invariant violated! Reject auto-merge, record conflict
                await tx.execute('''
                  UPDATE _sync_outbox 
                  SET status = 'conflict', error_details_json = ? 
                  WHERE mutation_id = ?
                ''', [
                  jsonEncode({
                    'type': 'https://offline-sync.dev/errors/invariant-conflict',
                    'title': 'Invariant Validation Failed',
                    'detail': invariantError,
                  }),
                  mutId
                ]);
                continue;
              }
            }

            // Invariants passed: apply merged row and update mutation baseline
            await _upsertRow(tx, entity, id, merged, version, now, jsonEncode(remoteData));
            await tx.execute('''
              UPDATE _sync_outbox 
              SET payload_json = ?, base_snapshot_json = ?, base_version = ? 
              WHERE mutation_id = ?
            ''', [jsonEncode(merged), jsonEncode(remoteData), version, mutId]);
          }
        }

        // Commit checkpoint cursor
        await tx.execute(
          'INSERT OR REPLACE INTO _sync_metadata (key, value) VALUES (?, ?)',
          ['last_synced_cursor', nextCursor.toString()],
        );
      });

      return SyncPullResult(
        status: SyncPullStatus.success,
        changeCount: changes.length,
        nextCursor: nextCursor,
        hasMore: hasMore,
      );
    } catch (e) {
      return SyncPullResult(status: SyncPullStatus.networkError, errorMessage: e.toString());
    }
  }

  static Future<void> _upsertRow(
    SqliteWriteContext tx,
    String entity,
    String id,
    Map<String, dynamic> data,
    int version,
    int now,
    String? baseSnapshot,
  ) async {
    final cols = <String>['id', 'version', 'updated_at', '_base_snapshot_json'];
    final vals = <dynamic>[id, version, now, baseSnapshot];

    for (final entry in data.entries) {
      if (entry.key != 'id' && entry.key != 'version' && entry.key != 'updated_at' && entry.key != '_base_snapshot_json') {
        cols.add(entry.key);
        vals.add(entry.value);
      }
    }

    final colStr = cols.join(', ');
    final phStr = cols.map((_) => '?').join(', ');
    await tx.execute('INSERT OR REPLACE INTO $entity ($colStr) VALUES ($phStr)', vals);
  }

  /// Continues pulling all available pages until has_more is false.
  Future<int> pullAll() async {
    int totalChanges = 0;
    while (true) {
      final res = await pullPage();
      if (res.status != SyncPullStatus.success) break;
      totalChanges += res.changeCount;
      if (!res.hasMore) break;
    }
    return totalChanges;
  }

  /// Performs an atomic generation swap to recover from HTTP 410 Gone.
  /// Pulls current snapshot into staging tables, swaps active tables atomically,
  /// and reapplies pending outbox mutations.
  /// ponytail: uses SQLite ALTER TABLE RENAME swap; upgrade to schema-copy migration if foreign key cycles are present.
  Future<bool> resyncGeneration(List<String> entities) async {
    // 1. Pull snapshot from server
    final uriStr = '$serverUrl/sync/pull?snapshot=true&limit=1000';
    final req = await httpClient.openUrl('GET', Uri.parse(uriStr));
    final resp = await req.close();
    if (resp.statusCode != HttpStatus.ok) return false;

    final respBody = await utf8.decoder.bind(resp).join();
    final bodyJson = jsonDecode(respBody) as Map<String, dynamic>;
    final changes = (bodyJson['changes'] as List).cast<Map<String, dynamic>>();
    final nextCursor = bodyJson['next_cursor'] as int;

    // 2. Perform atomic table swap in writeTransaction
    await storage.db.writeTransaction((tx) async {
      for (final entity in entities) {
        // Create staging table with identical schema
        await tx.execute('CREATE TABLE _staging_$entity AS SELECT * FROM $entity WHERE 0;');

        // Populate staging table with latest remote changes
        final entityChanges = changes.where((c) => c['entity'] == entity && c['_deleted'] != true);
        for (final change in entityChanges) {
          final id = change['id'].toString();
          final data = (change['data'] as Map<String, dynamic>?) ?? {};
          final version = (change['version'] as int?) ?? 1;
          final now = DateTime.now().millisecondsSinceEpoch;
          await _upsertRow(tx, '_staging_$entity', id, data, version, now, null);
        }

        // Atomic swap
        await tx.execute('DROP TABLE IF EXISTS _old_$entity;');
        await tx.execute('ALTER TABLE $entity RENAME TO _old_$entity;');
        await tx.execute('ALTER TABLE _staging_$entity RENAME TO $entity;');
        await tx.execute('DROP TABLE _old_$entity;');

        // Reapply pending outbox mutations on top of newly swapped active table
        final pending = await tx.getAll(
          "SELECT * FROM _sync_outbox WHERE entity_name = ? AND status = 'pending' ORDER BY created_at ASC",
          [entity],
        );

        for (final p in pending) {
          final id = p['entity_id'] as String;
          final op = p['op'] as String;
          if (op == 'delete') {
            await tx.execute('DELETE FROM $entity WHERE id = ?', [id]);
          } else {
            final payload = jsonDecode(p['payload_json'] as String) as Map<String, dynamic>;
            final now = DateTime.now().millisecondsSinceEpoch;
            await _upsertRow(tx, entity, id, payload, (p['base_version'] as int?) ?? 1, now, p['base_snapshot_json'] as String?);
          }
        }
      }

      // Update cursor to latest
      await tx.execute(
        'INSERT OR REPLACE INTO _sync_metadata (key, value) VALUES (?, ?)',
        ['last_synced_cursor', nextCursor.toString()],
      );
    });

    return true;
  }
}
