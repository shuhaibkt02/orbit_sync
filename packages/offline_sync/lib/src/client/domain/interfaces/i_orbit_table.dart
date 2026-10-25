import 'dart:async';
import '../models/orbit_record.dart';

/// Strongly-typed entity table handle providing compile-time safe CRUD,
/// automated SQLite sanitization, and reactive stream subscriptions.
abstract class IOrbitTable<T> {
  /// Entity/table name in SQLite.
  String get name;

  /// Primary key column name (defaults to 'id').
  String get primaryKey;

  /// Optimistically stores an entity record offline, queuing it for sync.
  Future<String> save(
    T item, {
    Duration? sla,
    Duration? holdFor,
    Duration? ttl,
    int priority = 0,
    String? correlationTag,
  });

  /// Deletes a record by ID, optionally holding it in an undo grace window.
  Future<String?> delete(String id, {Duration? undoWindow});

  /// Reverses an un-synced deletion during its undo grace window.
  Future<bool> undoDelete(String id);

  /// Retrieves a single record by primary key from local storage.
  Future<T?> get(String id);

  /// Queries records matching [where] with parameterized [whereArgs].
  Future<List<T>> query({
    String? where,
    List<dynamic> whereArgs = const [],
    String? orderBy,
    int? limit,
  });

  /// Watches query updates reactively with leading-immediate debounce.
  Stream<List<T>> watch({
    String? where,
    List<dynamic> whereArgs = const [],
    String? orderBy,
    int? limit,
  });

  /// Reactive stream coupling domain data with sync status metadata.
  Stream<List<OrbitRecord<T>>> watchRecords();

  /// Raw SQL query watcher returning typed domain models.
  Stream<List<T>> watchRaw(String query, [List<dynamic> parameters = const []]);

  /// Pulls remote snapshot from configured REST endpoint and UPSERTs cleanly.
  Future<int> refresh({Map<String, dynamic>? params});
}
