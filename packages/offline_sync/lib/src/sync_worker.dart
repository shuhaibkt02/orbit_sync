import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:sqlite3/sqlite3.dart' show Row;
import 'package:sqlite_async/sqlite_async.dart' show SqliteWriteContext;
import 'sync_storage.dart';

enum SyncPushStatus { success, networkError, conflict, validationError, poisonPill, unauthorized }
enum SyncPullStatus { success, networkError, expiredCursor, unauthorized }

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
  final int pullPageLimit;
  final Map<String, dynamic>? scopeFilter;
  Future<String?> Function()? getAuthToken;
  Future<void> Function()? onAuthExpired;

  /// Business invariant validator across co-dependent fields.
  /// Returns null if valid, or an RFC 9457 error message string if invalid.
  String? Function(String entity, Map<String, dynamic> mergedRecord)? validateInvariants;

  SyncWorker({
    required this.storage,
    required this.serverUrl,
    HttpClient? client,
    this.pullPageLimit = 50,
    this.scopeFilter,
    this.getAuthToken,
    this.onAuthExpired,
    this.validateInvariants,
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
    await storage.db.execute('''
      UPDATE _sync_outbox 
      SET status = 'pending' 
      WHERE status = 'held' 
        AND depends_on_mutation_id IN (SELECT mutation_id FROM _sync_outbox WHERE status = 'synced');
    ''');

    // 1. Fetch pending candidates
    final pendingRaw = await storage.db.getAll(
      "SELECT * FROM _sync_outbox WHERE status = 'pending' ORDER BY created_at ASC LIMIT ?",
      [batchSize * 2],
    );

    if (pendingRaw.isEmpty) {
      return const SyncPushResult(status: SyncPushStatus.success, applied: 0);
    }

    // 2. Selective holding: filter out mutations whose parent is quarantined (dlq/conflict/held)
    final pending = <Row>[];
    for (final r in pendingRaw) {
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

    final mutations = pending.map((r) {
      final payloadJson = r['payload_json'] as String?;
      return {
        'entity': r['entity_name'],
        'id': r['entity_id'],
        'op': r['op'],
        'payload': payloadJson != null ? jsonDecode(payloadJson) : null,
        'version': r['base_version'],
      };
    }).toList();

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

      if (resp.statusCode == HttpStatus.unauthorized) {
        await storage.db.execute(
          "UPDATE _sync_outbox SET status = 'pending' WHERE mutation_id IN ($placeholders)",
          mutationIds,
        );
        if (onAuthExpired != null) {
          await onAuthExpired!();
        }
        return const SyncPushResult(status: SyncPushStatus.unauthorized);
      }

      if (resp.statusCode == HttpStatus.badRequest) {
        await storage.db.execute('''
          UPDATE _sync_outbox 
          SET status = 'dlq', error_details_json = ? 
          WHERE mutation_id = ?
        ''', [respBody, mutationIds.first]);

        if (mutationIds.length > 1) {
          final remaining = mutationIds.sublist(1);
          final remPlaceholders = List.filled(remaining.length, '?').join(', ');
          await storage.db.execute(
            "UPDATE _sync_outbox SET status = 'pending' WHERE mutation_id IN ($remPlaceholders)",
            remaining,
          );
        }
        return SyncPushResult(status: SyncPushStatus.poisonPill, errorMessage: respBody);
      }

      if (resp.statusCode == HttpStatus.conflict) {
        return SyncPushResult(status: SyncPushStatus.conflict, details: bodyJson);
      }

      if (resp.statusCode == HttpStatus.unprocessableEntity) {
        // Rollback optimistic active row to base snapshot; preserve draft in outbox
        await storage.rollbackOptimistic(mutationIds.first, status: 'validation_error');
        await storage.db.execute(
          'UPDATE _sync_outbox SET error_details_json = ? WHERE mutation_id = ?',
          [respBody, mutationIds.first],
        );
        return SyncPushResult(status: SyncPushStatus.validationError, details: bodyJson);
      }

      if (resp.statusCode == HttpStatus.ok) {
        await storage.db.execute(
          "UPDATE _sync_outbox SET status = 'synced' WHERE mutation_id IN ($placeholders)",
          mutationIds,
        );
        return SyncPushResult(status: SyncPushStatus.success, applied: mutations.length);
      }

      throw HttpException('HTTP ${resp.statusCode}: $respBody');
    } catch (e) {
      await storage.db.execute(
        "UPDATE _sync_outbox SET status = 'pending' WHERE mutation_id IN ($placeholders)",
        mutationIds,
      );
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
          } else {
            // Pending local mutation exists: perform 3-way field merge
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
