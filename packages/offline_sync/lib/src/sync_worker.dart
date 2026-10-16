import 'dart:async';
import 'dart:convert';
import 'dart:io';
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

/// Bidirectional sync worker handling push queue and checkpointed pull streams.
class SyncWorker {
  final SyncStorage storage;
  final String serverUrl;
  final HttpClient httpClient;
  final int pullPageLimit;
  final Map<String, dynamic>? scopeFilter;
  Future<String?> Function()? getAuthToken;
  Future<void> Function()? onAuthExpired;

  SyncWorker({
    required this.storage,
    required this.serverUrl,
    HttpClient? client,
    this.pullPageLimit = 50,
    this.scopeFilter,
    this.getAuthToken,
    this.onAuthExpired,
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
  Future<SyncPushResult> pushBatch({int batchSize = 10, String? chaos}) async {
    // 1. Fetch pending mutations in chronological order (UUIDv7 / created_at)
    final pending = await storage.db.getAll(
      "SELECT * FROM _sync_outbox WHERE status = 'pending' ORDER BY created_at ASC LIMIT ?",
      [batchSize],
    );

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

    // Build payload
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

    // Idempotency key: single mutation uses its mutation_id, batch uses first id or combined
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
        // Auth expired: pause queue and trigger refresh; do NOT burn retry budget
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
        // Poison pill: route offending item to 'dlq' without blocking the entire queue
        await storage.db.execute('''
          UPDATE _sync_outbox 
          SET status = 'dlq', error_details_json = ? 
          WHERE mutation_id = ?
        ''', [respBody, mutationIds.first]);

        // Revert any remaining batch items to pending
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
        return SyncPushResult(status: SyncPushStatus.validationError, details: bodyJson);
      }

      if (resp.statusCode == HttpStatus.ok) {
        // Mark all pushed mutations as synced
        await storage.db.execute(
          "UPDATE _sync_outbox SET status = 'synced' WHERE mutation_id IN ($placeholders)",
          mutationIds,
        );
        return SyncPushResult(status: SyncPushStatus.success, applied: mutations.length);
      }

      throw HttpException('HTTP ${resp.statusCode}: $respBody');
    } catch (e) {
      // Revert in_flight to pending on network / socket drop so it will retry
      await storage.db.execute(
        "UPDATE _sync_outbox SET status = 'pending' WHERE mutation_id IN ($placeholders)",
        mutationIds,
      );
      return SyncPushResult(status: SyncPushStatus.networkError, errorMessage: e.toString());
    }
  }

  /// Pulls a single page of changes from GET /sync/pull and commits them checkpointed.
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

      // Atomically apply server changes directly into local domain tables
      // AND checkpoint the new cursor in _sync_metadata
      await storage.db.writeTransaction((tx) async {
        for (final change in changes) {
          final entity = change['entity'] as String;
          final id = change['id'].toString();
          final isDeleted = change['_deleted'] == true;
          final isLeftScope = change['left_scope'] == true;

          if (isDeleted || isLeftScope) {
            // Evict row locally without creating an outbox mutation
            await tx.execute('DELETE FROM $entity WHERE id = ?', [id]);
          } else {
            final data = (change['data'] as Map<String, dynamic>?) ?? {};
            final version = (change['version'] as int?) ?? 1;
            final now = DateTime.now().millisecondsSinceEpoch;

            final cols = <String>['id', 'version', 'updated_at', '_base_snapshot_json'];
            final vals = <dynamic>[id, version, now, null];

            for (final entry in data.entries) {
              if (entry.key != 'id' && entry.key != 'version' && entry.key != 'updated_at') {
                cols.add(entry.key);
                vals.add(entry.value);
              }
            }

            final colStr = cols.join(', ');
            final phStr = cols.map((_) => '?').join(', ');
            await tx.execute(
              'INSERT OR REPLACE INTO $entity ($colStr) VALUES ($phStr)',
              vals,
            );
          }
        }

        // Commit checkpoint cursor in the same atomic transaction
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
}
