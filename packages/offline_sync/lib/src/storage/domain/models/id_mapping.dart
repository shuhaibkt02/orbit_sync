/// Domain entity representing local temporary ID to canonical server ID mapping.
class IdMapping {
  final String entityName;
  final String localTempId;
  final String canonicalServerId;
  final int createdAt;

  const IdMapping({
    required this.entityName,
    required this.localTempId,
    required this.canonicalServerId,
    required this.createdAt,
  });

  factory IdMapping.fromMap(Map<String, dynamic> map) {
    return IdMapping(
      entityName: map['entity_name'] as String,
      localTempId: map['local_temp_id'] as String,
      canonicalServerId: map['canonical_server_id'] as String,
      createdAt: (map['created_at'] as int?) ?? 0,
    );
  }
}
