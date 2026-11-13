import 'dart:convert';
import 'package:sqlite_async/sqlite_async.dart';
import '../../domain/validation/sync_validator.dart';
import '../uuid/uuid_v7.dart';
import 'sqlite_schema.dart';
import 'sqlite_baseline_manager.dart';

/// SQLite helper for saving domain entities and staging outbox mutations.
class SqliteOutboxWriter {
  static Future<String> save({
    required SqliteDatabase db,
    required Set<String> knownColumns,
    required String entity,
    required String id,
    required Map<String, dynamic> data,
    int version = 1,
    String? dependsOnMutationId,
    int schemaVersion = 1,
    String? endpointUrl,
    String? httpMethod,
    Duration? holdFor,
    Duration? coolingTime,
    Duration? sla,
    Duration? ttl,
    int priority = 1,
    String? correlationTag,
    Map<String, String>? headers,
    String? authorId,
    String? userId,
    String? mediaPath,
  }) async {
    final effectiveHoldFor = coolingTime ?? holdFor;
    SyncValidator.validateEntity(entity);
    SyncValidator.validateId(id);
    SyncValidator.validateVersion(version);
    SyncValidator.validatePriority(priority);
    SyncValidator.validateDuration(effectiveHoldFor, 'holdFor');
    SyncValidator.validateDuration(sla, 'sla');
    SyncValidator.validateDuration(ttl, 'ttl');
    SyncValidator.validateHttpMethod(httpMethod);

    final cleanPayloadJson = SyncValidator.encodePayload(data);
    final effectiveAuthorId = authorId ??
        (data['author_id'] as String?) ??
        (data['authorId'] as String?);
    final effectiveUserId =
        userId ?? (data['user_id'] as String?) ?? (data['userId'] as String?);
    final effectiveMediaPath = mediaPath ??
        (data['media_path'] as String?) ??
        (data['mediaPath'] as String?);
    final effectiveDependsOn =
        dependsOnMutationId ?? (data['depends_on_mutation_id'] as String?);
    final effectivePriority = (data['priority'] is int &&
            (data['priority'] as int) >= 0 &&
            (data['priority'] as int) <= 3)
        ? (data['priority'] as int)
        : priority;

    return await db.writeTransaction<String>((tx) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final dispatchAfter = effectiveHoldFor != null
          ? now + effectiveHoldFor.inMilliseconds
          : null;
      final slaSeconds = sla?.inSeconds ??
          ((data['sla_seconds'] is int) ? (data['sla_seconds'] as int) : 86400);
      final expiresAt = ttl != null ? now + ttl.inMilliseconds : null;

      await SqliteSchema.ensureEntityTableExists(tx, knownColumns, entity);

      final baseline =
          await SqliteBaselineManager.readExistingBaseline(tx, entity, id);
      final baseSnapshotJson = baseline.snapshot;
      final baseVersion = baseline.version;

      await tx.execute(
        'INSERT OR REPLACE INTO "$entity" ("id", "version", "updated_at", "expires_at", "data_json") VALUES (?, ?, ?, ?, ?)',
        [id, version, now, expiresAt, cleanPayloadJson],
      );

      final pendingMutations = await tx.getAll(
        "SELECT mutation_id, payload_json, revision_history_json FROM _sync_outbox WHERE entity_name = ? AND entity_id = ? AND status = 'pending' AND op != 'delete' AND dispatch_after > ? ORDER BY sequence_id DESC LIMIT 1",
        [entity, id, now],
      );

      if (pendingMutations.isNotEmpty) {
        final existing = pendingMutations.first;
        final existingMutationId = existing['mutation_id'] as String;
        final oldPayload = existing['payload_json'] as String?;
        final oldHistoryJson = existing['revision_history_json'] as String?;

        List<dynamic> history = [];
        if (oldHistoryJson != null && oldHistoryJson.isNotEmpty) {
          try {
            history = jsonDecode(oldHistoryJson) as List<dynamic>;
          } catch (_) {}
        }

        if (oldPayload != null) {
          dynamic snapshot;
          try {
            snapshot = jsonDecode(oldPayload);
          } catch (_) {
            snapshot = oldPayload;
          }
          history.add({
            'timestamp': now,
            'snapshot': snapshot,
          });
        }

        await tx.execute('''
          UPDATE _sync_outbox
          SET payload_json = ?,
              revision_history_json = ?,
              dispatch_after = COALESCE(?, dispatch_after),
              headers_json = COALESCE(?, headers_json),
              author_id = COALESCE(?, author_id),
              user_id = COALESCE(?, user_id),
              media_path = COALESCE(?, media_path),
              priority = ?,
              sla_seconds = ?,
              updated_at = ?
          WHERE mutation_id = ?
        ''', [
          cleanPayloadJson,
          jsonEncode(history),
          dispatchAfter,
          headers != null ? jsonEncode(headers) : null,
          effectiveAuthorId,
          effectiveUserId,
          effectiveMediaPath,
          effectivePriority,
          slaSeconds,
          now,
          existingMutationId,
        ]);

        return existingMutationId;
      }

      final mutationId = UuidV7.generate();
      final op = baseSnapshotJson == null ? 'create' : 'update';
      final method = httpMethod ?? (baseSnapshotJson == null ? 'POST' : 'PUT');

      var initialStatus = 'pending';
      if (effectiveDependsOn != null) {
        final parentRows = await tx.getAll(
          'SELECT status FROM _sync_outbox WHERE mutation_id = ?',
          [effectiveDependsOn],
        );
        if (parentRows.isEmpty || parentRows.first['status'] != 'synced') {
          initialStatus = 'held';
        }
      }

      await tx.execute('''
        INSERT INTO _sync_outbox (
          mutation_id,
          entity_name,
          entity_id,
          op,
          endpoint_url,
          http_method,
          payload_json,
          headers_json,
          base_snapshot_json,
          base_version,
          status,
          author_id,
          user_id,
          media_path,
          depends_on_mutation_id,
          correlation_tag,
          priority,
          sla_seconds,
          schema_version,
          dispatch_after,
          created_at,
          updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''', [
        mutationId,
        entity,
        id,
        op,
        endpointUrl,
        method,
        cleanPayloadJson,
        headers != null ? jsonEncode(headers) : null,
        baseSnapshotJson,
        baseVersion,
        initialStatus,
        effectiveAuthorId,
        effectiveUserId,
        effectiveMediaPath,
        effectiveDependsOn,
        correlationTag,
        effectivePriority,
        slaSeconds,
        schemaVersion,
        dispatchAfter,
        now,
        now,
      ]);

      return mutationId;
    });
  }
}
