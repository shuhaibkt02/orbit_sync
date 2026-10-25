import 'dart:convert';
import '../domain/interfaces/i_conflict_resolver.dart';

/// Reconciles concurrent local edits and remote server changes using 3-way merge
/// and pluggable join-semilattice resolvers.
class ConflictReconciler {
  final Map<String, EntityConflictResolver> _resolvers = {};
  final InvariantValidator? validateInvariants;

  ConflictReconciler({
    Map<String, EntityConflictResolver>? resolvers,
    this.validateInvariants,
  }) {
    if (resolvers != null) {
      _resolvers.addAll(resolvers);
    }
  }

  /// Registers a custom entity-specific CRDT or join-semilattice conflict resolver.
  void registerResolver(String entity, EntityConflictResolver resolver) {
    _resolvers[entity] = resolver;
  }

  /// Reconciles concurrent versions of an entity record.
  /// Returns a record with the merged data, or an error RFC 9457 JSON string if invariant fails.
  ({Map<String, dynamic>? merged, String? invariantError}) reconcile({
    required String entity,
    required Map<String, dynamic>? baseSnapshot,
    required Map<String, dynamic> localRecord,
    required Map<String, dynamic> remoteRecord,
  }) {
    Map<String, dynamic> mergedData;

    // 1. Pluggable custom resolver if registered
    if (_resolvers.containsKey(entity)) {
      mergedData = _resolvers[entity]!(
        baseSnapshot: baseSnapshot,
        localRecord: localRecord,
        remoteRecord: remoteRecord,
      );
    } else {
      // 2. Default column-level 3-way merge
      // ponytail: remote precedence on collision; upgrade to CRDT only for character diffing
      mergedData = Map<String, dynamic>.from(remoteRecord);
      final base = baseSnapshot ?? const {};

      for (final key in localRecord.keys) {
        if (localRecord[key] != base[key]) {
          // Local made a change to this column
          mergedData[key] = localRecord[key];
        }
      }
    }

    // 3. Business invariant validation across co-dependent columns
    if (validateInvariants != null) {
      final error = validateInvariants!(entity, mergedData);
      if (error != null) {
        final rfcError = jsonEncode({
          'type': 'https://offline-sync.dev/errors/invariant-conflict',
          'title': 'Invariant Validation Failed',
          'detail': error,
        });
        return (merged: null, invariantError: rfcError);
      }
    }

    return (merged: mergedData, invariantError: null);
  }
}
