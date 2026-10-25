import 'dart:convert';
import 'dart:typed_data';
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
    Duration? sla,
    Duration? ttl,
    int priority = 0,
    String? correlationTag,
  }) async {
    SyncValidator.validateEntity(entity);
    SyncValidator.validateId(id);
    SyncValidator.validateVersion(version);
    SyncValidator.validatePriority(priority);
    SyncValidator.validateDuration(holdFor, 'holdFor');
    SyncValidator.validateDuration(sla, 'sla');
    SyncValidator.validateDuration(ttl, 'ttl');
    SyncValidator.validateHttpMethod(httpMethod);

    final cleanPayloadJson = SyncValidator.encodePayload(data);

    return await db.writeTransaction<String>((tx) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final dispatchAfter = holdFor != null ? now + holdFor.inMilliseconds : now;
      final slaSeconds = sla?.inSeconds ?? 86400;
      final expiresAt = ttl != null ? now + ttl.inMilliseconds : null;

      await SqliteSchema.ensureEntityTableExists(tx, knownColumns, entity);

      final baseline = await SqliteBaselineManager.readExistingBaseline(tx, entity, id);
      final baseSnapshotJson = baseline.snapshot;
      final baseVersion = baseline.version;

      for (final entry in data.entries) {
        final key = entry.key;
        if (!SqliteSchema.systemEntityCols.contains(key)) {
          if (knownColumns.contains('$entity:$key')) continue;
          try {
            final val = entry.value;
            final String colType = val is int
                ? 'INTEGER'
                : val is double
                    ? 'REAL'
                    : val is bool
                        ? 'INTEGER'
                        : (val is Uint8List)
                            ? 'BLOB'
                            : 'TEXT';
            await tx.execute('ALTER TABLE "$entity" ADD COLUMN "$key" $colType');
          } catch (_) {}
          knownColumns.add('$entity:$key');
        }
      }

      final columns = <String>['id', 'version', 'updated_at', 'expires_at', '_base_snapshot_json', 'data_json'];
      final values = <dynamic>[id, version, now, expiresAt, baseSnapshotJson, cleanPayloadJson];

      for (final entry in data.entries) {
        if (!SqliteSchema.systemEntityCols.contains(entry.key)) {
          columns.add(entry.key);
          final val = entry.value;
          if (val is bool) {
            values.add(val ? 1 : 0);
          } else if (val is Map || (val is List && val is! Uint8List)) {
            values.add(jsonEncode(val));
          } else {
            values.add(val);
          }
        }
      }

      final colList = columns.map((c) => '"$c"').join(', ');
      final placeholders = columns.map((_) => '?').join(', ');

      await tx.execute(
        'INSERT OR REPLACE INTO "$entity" ($colList) VALUES ($placeholders)',
        values,
      );

      final pendingMutations = await tx.getAll(
        "SELECT mutation_id, payload_json, revision_history_json FROM _sync_outbox WHERE entity_name = ? AND entity_id = ? AND status = 'pending' AND dispatch_after > ? ORDER BY sequence_id DESC LIMIT 1",
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
          history.add({
            'timestamp': now,
            'snapshot': jsonDecode(oldPayload),
          });
        }

        await tx.execute('''
          UPDATE _sync_outbox
          SET payload_json = ?,
              revision_history_json = ?,
              updated_at = ?
          WHERE mutation_id = ?
        ''', [
          cleanPayloadJson,
          jsonEncode(history),
          now,
          existingMutationId,
        ]);

        return existingMutationId;
      }

      final mutationId = UuidV7.generate();
      final op = baseSnapshotJson == null ? 'create' : 'update';
      final method = httpMethod ?? (baseSnapshotJson == null ? 'POST' : 'PUT');

      await tx.execute('''
        INSERT INTO _sync_outbox (
          mutation_id,
          entity_name,
          entity_id,
          op,
          endpoint_url,
          http_method,
          payload_json,
          base_snapshot_json,
          base_version,
          depends_on_mutation_id,
          correlation_tag,
          priority,
          sla_seconds,
          schema_version,
          dispatch_after,
          created_at,
          updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''', [
        mutationId,
        entity,
        id,
        op,
        endpointUrl,
        method,
        cleanPayloadJson,
        baseSnapshotJson,
        baseVersion,
        dependsOnMutationId,
        correlationTag,
        priority,
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
