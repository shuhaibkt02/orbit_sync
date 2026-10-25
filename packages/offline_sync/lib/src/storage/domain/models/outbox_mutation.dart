/// Pure immutable domain entity representing an outbox mutation envelope.
class OutboxMutation {
  final int? sequenceId;
  final String mutationId;
  final String entityName;
  final String entityId;
  final String op;
  final String? endpointUrl;
  final String? httpMethod;
  final String? payloadJson;
  final String? baseSnapshotJson;
  final int baseVersion;
  final String status;
  final String? dependsOnMutationId;
  final String? correlationTag;
  final int priority;
  final int slaSeconds;
  final int schemaVersion;
  final String? errorDetailsJson;
  final int? dispatchAfter;
  final String? revisionHistoryJson;
  final int retryCount;
  final int? nextRetryAt;
  final int createdAt;
  final int updatedAt;

  const OutboxMutation({
    this.sequenceId,
    required this.mutationId,
    required this.entityName,
    required this.entityId,
    required this.op,
    this.endpointUrl,
    this.httpMethod,
    this.payloadJson,
    this.baseSnapshotJson,
    this.baseVersion = 1,
    this.status = 'pending',
    this.dependsOnMutationId,
    this.correlationTag,
    this.priority = 0,
    this.slaSeconds = 86400,
    this.schemaVersion = 1,
    this.errorDetailsJson,
    this.dispatchAfter,
    this.revisionHistoryJson,
    this.retryCount = 0,
    this.nextRetryAt,
    required this.createdAt,
    required this.updatedAt,
  });

  factory OutboxMutation.fromMap(Map<String, dynamic> map) {
    return OutboxMutation(
      sequenceId: map['sequence_id'] as int?,
      mutationId: map['mutation_id'] as String,
      entityName: map['entity_name'] as String,
      entityId: map['entity_id'] as String,
      op: map['op'] as String,
      endpointUrl: map['endpoint_url'] as String?,
      httpMethod: map['http_method'] as String?,
      payloadJson: map['payload_json'] as String?,
      baseSnapshotJson: map['base_snapshot_json'] as String?,
      baseVersion: (map['base_version'] as int?) ?? 1,
      status: (map['status'] as String?) ?? 'pending',
      dependsOnMutationId: map['depends_on_mutation_id'] as String?,
      correlationTag: map['correlation_tag'] as String?,
      priority: (map['priority'] as int?) ?? 0,
      slaSeconds: (map['sla_seconds'] as int?) ?? 86400,
      schemaVersion: (map['schema_version'] as int?) ?? 1,
      errorDetailsJson: map['error_details_json'] as String?,
      dispatchAfter: map['dispatch_after'] as int?,
      revisionHistoryJson: map['revision_history_json'] as String?,
      retryCount: (map['retry_count'] as int?) ?? 0,
      nextRetryAt: map['next_retry_at'] as int?,
      createdAt: (map['created_at'] as int?) ?? 0,
      updatedAt: (map['updated_at'] as int?) ?? 0,
    );
  }
}
