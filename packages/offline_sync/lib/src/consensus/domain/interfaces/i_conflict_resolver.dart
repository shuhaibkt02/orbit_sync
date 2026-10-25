/// Pluggable CRDT join-semilattice resolver for non-scalar domain collisions.
///
/// Takes [baseSnapshot] (prior baseline before offline edit), [localRecord]
/// (client optimistic edit), and [remoteRecord] (latest remote server payload).
/// Returns the mathematically merged record.
typedef EntityConflictResolver = Map<String, dynamic> Function({
  required Map<String, dynamic>? baseSnapshot,
  required Map<String, dynamic> localRecord,
  required Map<String, dynamic> remoteRecord,
});

/// Business invariant validator across co-dependent fields.
/// Returns null if valid, or an RFC 9457 error message string if invalid.
typedef InvariantValidator = String? Function(
  String entity,
  Map<String, dynamic> mergedRecord,
);
