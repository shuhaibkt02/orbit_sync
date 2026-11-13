import 'dart:convert';
import 'package:sqlite3/sqlite3.dart' show Row;
import 'sync_failure.dart';

/// High-level summary of outbox sync state for dashboards and UI widgets.
class SyncStatusSummary {
  final int pending;
  final int inFlight;
  final int synced;
  final int failed;
  final int total;
  final DateTime? oldestPendingAt;

  const SyncStatusSummary({
    required this.pending,
    required this.inFlight,
    required this.synced,
    required this.failed,
    required this.total,
    this.oldestPendingAt,
  });

  /// True if there are zero pending mutations and zero failures.
  bool get isClean => pending == 0 && inFlight == 0 && failed == 0;

  /// True if any mutations have permanently failed or entered DLQ.
  bool get hasFailures => failed > 0;

  /// Age of the oldest unsynced mutation, or null if outbox has no pending items.
  Duration? get oldestPendingAge => oldestPendingAt != null
      ? DateTime.now().difference(oldestPendingAt!)
      : null;

  @override
  String toString() =>
      'SyncStatusSummary(pending: $pending, inFlight: $inFlight, synced: $synced, failed: $failed, total: $total)';
}

/// Represents a single mutation record in the outbox with typed metadata.
class OutboxRecord {
  final String mutationId;
  final String entity;
  final String recordId;
  final String operation;
  final String status;
  final DateTime createdAt;
  final int retryCount;
  final String? endpointUrl;
  final Map<String, dynamic>? payload;
  final SyncFailure? failure;

  const OutboxRecord({
    required this.mutationId,
    required this.entity,
    required this.recordId,
    required this.operation,
    required this.status,
    required this.createdAt,
    required this.retryCount,
    this.endpointUrl,
    this.payload,
    this.failure,
  });

  /// The elapsed time since this mutation was queued offline.
  Duration get age => DateTime.now().difference(createdAt);

  /// True if this mutation has breached [maxAge] without syncing.
  bool isStale(Duration maxAge) => age > maxAge;

  /// True if this mutation is in a terminal error state (DLQ or validation failure).
  bool get isFailed =>
      status == 'failed' || status == 'dlq' || status == 'validation_error';

  /// Constructs an [OutboxRecord] from a SQLite outbox row.
  factory OutboxRecord.fromRow(Row row) {
    Map<String, dynamic>? payloadMap;
    final payloadStr = row['payload_json'] as String?;
    if (payloadStr != null && payloadStr.isNotEmpty) {
      try {
        payloadMap = jsonDecode(payloadStr) as Map<String, dynamic>?;
      } catch (_) {}
    }

    SyncFailure? failure;
    final status = (row['status'] as String?) ?? 'pending';
    if (status == 'failed' || status == 'dlq' || status == 'validation_error') {
      try {
        failure = SyncFailure.fromRow(row);
      } catch (_) {}
    }

    final createdAtEpoch = (row['created_at'] as int?) ?? 0;

    return OutboxRecord(
      mutationId: row['mutation_id'] as String,
      entity: row['entity_name'] as String,
      recordId: row['entity_id'] as String,
      operation: row['op'] as String,
      status: status,
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAtEpoch),
      retryCount: (row['retry_count'] as int?) ?? 0,
      endpointUrl: row['endpoint_url'] as String?,
      payload: payloadMap,
      failure: failure,
    );
  }

  @override
  String toString() =>
      'OutboxRecord(id: $mutationId, entity: $entity, status: $status, age: ${age.inMinutes}m)';
}
