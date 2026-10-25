import 'dart:convert';
import 'package:sqlite3/sqlite3.dart' show Row;

/// Represents a mutation that failed to synchronize with the server.
class SyncFailure {
  final String mutationId;
  final String entity;
  final String recordId;
  final String op;
  final String? endpointUrl;
  final int? statusCode;
  final String errorMessage;
  final DateTime failedAt;
  final int retryCount;
  final Map<String, dynamic>? payload;

  const SyncFailure({
    required this.mutationId,
    required this.entity,
    required this.recordId,
    required this.op,
    this.endpointUrl,
    this.statusCode,
    required this.errorMessage,
    required this.failedAt,
    required this.retryCount,
    this.payload,
  });

  /// Factory to construct a typed [SyncFailure] from a SQLite outbox row.
  factory SyncFailure.fromRow(Row row) {
    int? code;
    String message = 'Unknown error';

    final detailsStr = row['error_details_json'] as String?;
    if (detailsStr != null && detailsStr.isNotEmpty) {
      try {
        final decoded = jsonDecode(detailsStr);
        if (decoded is Map<String, dynamic>) {
          code = decoded['statusCode'] as int?;
          message = (decoded['error'] as String?) ??
              (decoded['message'] as String?) ??
              (decoded['detail'] as String?) ??
              detailsStr;
        } else {
          message = detailsStr;
        }
      } catch (_) {
        message = detailsStr;
      }
    }

    Map<String, dynamic>? payloadMap;
    final payloadStr = row['payload_json'] as String?;
    if (payloadStr != null && payloadStr.isNotEmpty) {
      try {
        payloadMap = jsonDecode(payloadStr) as Map<String, dynamic>?;
      } catch (_) {}
    }

    return SyncFailure(
      mutationId: row['mutation_id'] as String,
      entity: row['entity_name'] as String,
      recordId: row['entity_id'] as String,
      op: row['op'] as String,
      endpointUrl: row['endpoint_url'] as String?,
      statusCode: code,
      errorMessage: message,
      failedAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      retryCount: (row['retry_count'] as int?) ?? 0,
      payload: payloadMap,
    );
  }

  @override
  String toString() =>
      'SyncFailure(entity: $entity, recordId: $recordId, code: $statusCode, error: $errorMessage)';
}
