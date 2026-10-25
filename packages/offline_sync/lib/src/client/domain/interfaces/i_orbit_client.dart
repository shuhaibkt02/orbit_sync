import 'dart:async';
import 'package:sqlite3/sqlite3.dart' show Row, ResultSet;
import '../models/orbit_sync_event.dart';
import '../models/sync_job.dart';
import '../models/rest_endpoints.dart';
import 'i_orbit_table.dart';

/// Top-level developer facade interface for the offline sync plugin.
abstract class IOrbitClient {
  /// Registers a strongly-typed entity table handle (Challenge 4).
  IOrbitTable<T> registerModel<T>({
    required String name,
    required T Function(Map<String, dynamic> json) fromJson,
    required Map<String, dynamic> Function(T item) toJson,
    String primaryKey = 'id',
    List<String> indexes = const [],
    List<String> foreignKeys = const [],
    RestEndpoints<T>? endpoints,
  });

  /// Registers an untyped table schema with custom columns, foreign keys, and endpoint URL.
  Future<void> registerTable(
    String entityName,
    Map<String, String> columnTypes, {
    String? foreignKeyClause,
    String? url,
  });

  /// Executes bidirectional sync (pull then drain outbox push) returning a [SyncJob].
  SyncJob sync({String? entity, bool force = false});

  /// Telemetry stream of sync events with correlation IDs.
  Stream<OrbitSyncEvent> get syncEvents;

  /// Restores records from local storage with optional SQL where clause.
  Future<List<Row>> query(String sql, [List<dynamic> parameters = const []]);

  /// Watches query updates reactively with leading-immediate debounce.
  Stream<ResultSet> watch(String query, {List<dynamic> parameters = const []});

  /// Closes database connections and stops timers with a graceful drain budget.
  Future<void> close({Duration drainTimeout = const Duration(seconds: 3)});
}
