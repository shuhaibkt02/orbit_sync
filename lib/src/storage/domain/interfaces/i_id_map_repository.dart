/// Inverted contract for ID mapping and re-keying repository.
abstract class IIdMapRepository {
  /// Records a local temporary ID to canonical server ID mapping.
  Future<void> registerServerId({
    required String entity,
    required String localTempId,
    required String canonicalServerId,
  });

  /// Resolves the canonical server ID for a local temporary ID.
  Future<String?> getCanonicalServerId({
    required String entity,
    required String localTempId,
  });

  /// Resolves the local temporary ID for a canonical server ID.
  Future<String?> getLocalTempId({
    required String entity,
    required String canonicalServerId,
  });
}
