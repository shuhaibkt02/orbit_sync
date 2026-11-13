import 'dart:convert';
import 'package:sqlite3/sqlite3.dart' show Row;

/// Sync status classifications exposed to application UI and diagnostics.
enum SyncItemStatus {
  pending,
  inFlight,
  synced,
  rejected,
  failed,
  held,
  dlq,
}

/// Rich developer-facing presentation model for an item in the synchronization pipeline.
class SyncItemInfo {
  final String mutationId;
  final String entityName;
  final String entityId;
  final SyncItemStatus status;
  final String? failureReason;
  final Duration? remainingSla;
  final DateTime createdAt;
  final Map<String, dynamic> data;

  const SyncItemInfo({
    required this.mutationId,
    required this.entityName,
    required this.entityId,
    required this.status,
    this.failureReason,
    this.remainingSla,
    required this.createdAt,
    this.data = const {},
  });

  /// True if this item has failed, been rejected by the server, or entered the dead-letter queue.
  bool get canRetry =>
      status == SyncItemStatus.rejected ||
      status == SyncItemStatus.failed ||
      status == SyncItemStatus.dlq;

  factory SyncItemInfo.fromRow(Row r, {int? nowMs}) {
    final now = nowMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;
    final rawStatus = (r['status'] as String?) ?? 'pending';
    final status = _parseStatus(rawStatus);
    final createdAtMs = (r['created_at'] as int?) ?? now;
    final slaSeconds = r['sla_seconds'] as int?;

    Duration? remaining;
    if (slaSeconds != null && slaSeconds > 0) {
      final deadlineMs = createdAtMs + (slaSeconds * 1000);
      remaining = Duration(milliseconds: deadlineMs - now);
    }

    final payloadJson = r['payload_json'] as String?;
    Map<String, dynamic> parsedData = const {};
    if (payloadJson != null && payloadJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(payloadJson);
        if (decoded is Map<String, dynamic>) {
          parsedData = decoded;
        } else if (decoded is Map) {
          parsedData = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {}
    }

    return SyncItemInfo(
      mutationId: (r['mutation_id'] as String?) ?? '',
      entityName: (r['entity_name'] as String?) ?? '',
      entityId: (r['entity_id'] as String?) ?? '',
      status: status,
      failureReason: r['error_details_json'] as String?,
      remainingSla: remaining,
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAtMs, isUtc: true),
      data: parsedData,
    );
  }

  static SyncItemStatus _parseStatus(String status) {
    switch (status) {
      case 'in_flight':
        return SyncItemStatus.inFlight;
      case 'synced':
        return SyncItemStatus.synced;
      case 'validation_error':
        return SyncItemStatus.rejected;
      case 'failed':
      case 'conflict':
        return SyncItemStatus.failed;
      case 'held':
        return SyncItemStatus.held;
      case 'dlq':
        return SyncItemStatus.dlq;
      case 'pending':
      default:
        return SyncItemStatus.pending;
    }
  }

  @override
  String toString() =>
      'SyncItemInfo(mutationId: $mutationId, entity: $entityName, id: $entityId, status: $status, canRetry: $canRetry)';
}
