/// Complete mutation container for schema migrations and outbox upgrades.
class MutationEnvelope {
  final String mutationId;
  final String entity;
  int schemaVersion;
  Map<String, dynamic> payload;
  Map<String, dynamic>? baseSnapshot;
  String? endpointUrl;
  String? httpMethod;

  MutationEnvelope({
    required this.mutationId,
    required this.entity,
    required this.schemaVersion,
    required this.payload,
    this.baseSnapshot,
    this.endpointUrl,
    this.httpMethod,
  });

  Map<String, dynamic> toMap() => {
        'mutation_id': mutationId,
        'entity': entity,
        'schema_version': schemaVersion,
        'payload': payload,
        'base_snapshot': baseSnapshot,
        'endpoint_url': endpointUrl,
        'http_method': httpMethod,
      };
}
