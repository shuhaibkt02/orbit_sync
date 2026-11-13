import 'package:sqlite3/sqlite3.dart' show ResultSet;
import 'package:sqlite_async/sqlite_async.dart';

import '../../domain/interfaces/i_outbox_repository.dart';
import 'sqlite_schema.dart';
import 'sqlite_outbox_writer.dart';
import 'sqlite_outbox_deleter.dart';
import 'sqlite_baseline_manager.dart';
import 'sqlite_cache_cleaner.dart';

/// Concrete SQLite implementation of IOutboxRepository.
/// Coordinates specialized SQLite operation handlers while maintaining ACID durability.
class SqliteOutboxRepository implements IOutboxRepository {
  final SqliteDatabase db;
  final Set<String> knownColumns;

  SqliteOutboxRepository(this.db, [Set<String>? knownColumns])
      : knownColumns = knownColumns ?? <String>{};

  @override
  Future<void> registerEntityTable(
    String entityName,
    Map<String, String> columnTypes, {
    String? foreignKeyClause,
  }) {
    return SqliteSchema.registerEntityTable(
      db,
      knownColumns,
      entityName,
      columnTypes,
      foreignKeyClause: foreignKeyClause,
    );
  }

  @override
  Future<String> save({
    required String entity,
    required String id,
    required Map<String, dynamic> data,
    int version = 1,
    String? dependsOnMutationId,
    int schemaVersion = 1,
    String? endpointUrl,
    String? httpMethod,
    Duration? holdFor,
    Duration? coolingTime,
    Duration? sla,
    Duration? ttl,
    int priority = 1,
    String? correlationTag,
    Map<String, String>? headers,
    String? authorId,
    String? userId,
    String? mediaPath,
  }) {
    return SqliteOutboxWriter.save(
      db: db,
      knownColumns: knownColumns,
      entity: entity,
      id: id,
      data: data,
      version: version,
      dependsOnMutationId: dependsOnMutationId,
      schemaVersion: schemaVersion,
      endpointUrl: endpointUrl,
      httpMethod: httpMethod,
      holdFor: holdFor,
      coolingTime: coolingTime,
      sla: sla,
      ttl: ttl,
      priority: priority,
      correlationTag: correlationTag,
      headers: headers,
      authorId: authorId,
      userId: userId,
      mediaPath: mediaPath,
    );
  }

  @override
  Future<String?> delete({
    required String entity,
    required String id,
    String? endpointUrl,
    String? httpMethod,
    Duration? undoWindow,
    Duration? coolingTime,
    Duration? holdFor,
    Map<String, String>? headers,
    String? authorId,
    String? userId,
  }) {
    return SqliteOutboxDeleter.delete(
      db: db,
      knownColumns: knownColumns,
      entity: entity,
      id: id,
      endpointUrl: endpointUrl,
      httpMethod: httpMethod,
      undoWindow: undoWindow,
      coolingTime: coolingTime,
      holdFor: holdFor,
      headers: headers,
      authorId: authorId,
      userId: userId,
    );
  }

  @override
  Future<bool> undoDelete({String? entity, required String id}) {
    return SqliteBaselineManager.undoDelete(db, entity: entity, id: id);
  }

  @override
  Future<void> rollbackOptimistic(String mutationId,
      {String status = 'conflict'}) {
    return SqliteBaselineManager.rollbackOptimistic(db, mutationId,
        status: status);
  }

  @override
  Future<int> pruneSyncedOutbox(
      {Duration retention = const Duration(days: 7)}) {
    return SqliteCacheCleaner.pruneSyncedOutbox(db, retention: retention);
  }

  @override
  Future<int> pruneSynced({Duration olderThan = const Duration(days: 7)}) {
    return SqliteCacheCleaner.pruneSynced(db, olderThan: olderThan);
  }

  @override
  Future<int> pruneExpiredCache(String entity) {
    return SqliteCacheCleaner.pruneExpiredCache(db, knownColumns, entity);
  }

  @override
  Future<int> pruneToQuota(String entity, {required int maxCacheRecords}) {
    return SqliteCacheCleaner.pruneToQuota(db, entity,
        maxCacheRecords: maxCacheRecords);
  }

  @override
  Future<ResultSet> query(String query, [List<dynamic> parameters = const []]) {
    return db.getAll(query, parameters);
  }

  @override
  Stream<ResultSet> watch(String query, {List<dynamic> parameters = const []}) {
    return db.watch(query, parameters: parameters);
  }

  @override
  Future<void> checkpoint({bool truncate = false}) {
    return SqliteCacheCleaner.checkpoint(db, truncate: truncate);
  }

  @override
  Future<void> close() async {
    await db.close();
  }
}
