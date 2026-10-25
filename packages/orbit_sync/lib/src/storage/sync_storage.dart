import 'dart:async';
import 'package:sqlite3/sqlite3.dart' show ResultSet;
import 'package:sqlite_async/sqlite_async.dart';

import 'domain/interfaces/i_outbox_repository.dart';
import 'domain/interfaces/i_id_map_repository.dart';
import 'domain/interfaces/i_storage_recovery.dart';
import 'infrastructure/sqlite/sqlite_recovery.dart';
import 'infrastructure/sqlite/storage_opener.dart';

export 'domain/models/outbox_mutation.dart';
export 'domain/models/id_mapping.dart';
export 'domain/validation/sync_validator.dart';
export 'domain/interfaces/i_outbox_repository.dart';
export 'domain/interfaces/i_id_map_repository.dart';
export 'domain/interfaces/i_storage_recovery.dart';
export 'infrastructure/uuid/uuid_v7.dart';
export 'infrastructure/sqlite/sqlite_schema.dart';
export 'infrastructure/sqlite/sqlite_recovery.dart';
export 'infrastructure/sqlite/storage_opener.dart';
export 'infrastructure/sqlite/sqlite_outbox_repository.dart';
export 'infrastructure/sqlite/sqlite_id_map_repository.dart';

/// Clean coordinator facade following SOLID & Clean Architecture.
/// Injects domain repository interfaces, manages lifecycle, and provides 0ms local operations.
class SyncStorage {
  final SqliteDatabase db;
  final String path;
  final IOutboxRepository _outboxRepo;
  final IIdMapRepository _idMapRepo;

  /// Dependency-injected constructor allowing custom domain repository implementations.
  SyncStorage.withRepositories({
    required this.db,
    required this.path,
    required IOutboxRepository outboxRepo,
    required IIdMapRepository idMapRepo,
  })  : _outboxRepo = outboxRepo,
        _idMapRepo = idMapRepo;

  /// Opens or creates database at [path] with connection pooling and recovery.
  static Future<SyncStorage> open({
    required String path,
    int maxReaders = 4,
    void Function(String corruptPath)? onDatabaseCorrupted,
    Future<bool> Function(String path)? backupShield,
    Future<String?> Function(String key)? secureStorageReader,
    Future<void> Function(String key, String value)? secureStorageWriter,
    void Function(String sqliteId, String secureId)? onTimeTravelBackupDetected,
    IStorageRecovery recovery = const SqliteRecovery(),
  }) =>
      StorageOpener.open(
        path: path,
        maxReaders: maxReaders,
        onDatabaseCorrupted: onDatabaseCorrupted,
        backupShield: backupShield,
        secureStorageReader: secureStorageReader,
        secureStorageWriter: secureStorageWriter,
        onTimeTravelBackupDetected: onTimeTravelBackupDetected,
        recovery: recovery,
      );

  /// Registers an entity table with custom columns and optional foreign key clauses.
  Future<void> registerEntityTable(
    String entityName,
    Map<String, String> columnTypes, {
    String? foreignKeyClause,
  }) =>
      _outboxRepo.registerEntityTable(entityName, columnTypes, foreignKeyClause: foreignKeyClause);

  /// Atomically commits domain entity record and outbox mutation envelope.
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
    Duration? sla,
    Duration? ttl,
    int priority = 0,
    String? correlationTag,
  }) =>
      _outboxRepo.save(
        entity: entity, id: id, data: data, version: version, dependsOnMutationId: dependsOnMutationId,
        schemaVersion: schemaVersion, endpointUrl: endpointUrl, httpMethod: httpMethod, holdFor: holdFor,
        sla: sla, ttl: ttl, priority: priority, correlationTag: correlationTag,
      );

  /// Atomically marks domain entity deleted and appends delete envelope to outbox.
  Future<String?> delete({
    required String entity,
    required String id,
    String? endpointUrl,
    String? httpMethod,
    Duration? undoWindow,
  }) =>
      _outboxRepo.delete(entity: entity, id: id, endpointUrl: endpointUrl, httpMethod: httpMethod, undoWindow: undoWindow);

  /// Restores a deleted record locally if within its undoWindow.
  Future<bool> undoDelete({required String entity, required String id}) =>
      _outboxRepo.undoDelete(entity: entity, id: id);

  /// Records a local temporary ID to canonical server ID mapping.
  Future<void> registerServerId({
    required String entity,
    required String localTempId,
    required String canonicalServerId,
  }) =>
      _idMapRepo.registerServerId(entity: entity, localTempId: localTempId, canonicalServerId: canonicalServerId);

  /// Resolves the canonical server ID for a local temporary ID.
  Future<String?> getCanonicalServerId({required String entity, required String localTempId}) =>
      _idMapRepo.getCanonicalServerId(entity: entity, localTempId: localTempId);

  /// Resolves the local temporary ID for a canonical server ID.
  Future<String?> getLocalTempId({required String entity, required String canonicalServerId}) =>
      _idMapRepo.getLocalTempId(entity: entity, canonicalServerId: canonicalServerId);

  /// Prunes completed synced outbox records older than [olderThan].
  Future<int> pruneSynced({Duration olderThan = const Duration(days: 7)}) =>
      _outboxRepo.pruneSynced(olderThan: olderThan);

  /// Prunes expired local domain cache records where `expires_at < now`.
  Future<int> pruneExpiredCache(String entity) => _outboxRepo.pruneExpiredCache(entity);

  /// Rolls back an optimistic mutation using its stored base snapshot.
  Future<void> rollbackOptimistic(String mutationId, {String status = 'conflict'}) =>
      _outboxRepo.rollbackOptimistic(mutationId, status: status);

  /// Executes an asynchronous query against SQLite and returns the result set.
  Future<ResultSet> query(String query, [List<dynamic> parameters = const []]) =>
      _outboxRepo.query(query, parameters);

  /// Streams reactive updates on any SQL query without requiring codegen TableInfo.
  Stream<ResultSet> watch(String query, {List<dynamic> parameters = const []}) =>
      _outboxRepo.watch(query, parameters: parameters);

  /// Triggers a WAL checkpoint. If [truncate] is true, shrinks WAL file to 0 bytes.
  Future<void> checkpoint({bool truncate = false}) => _outboxRepo.checkpoint(truncate: truncate);

  /// Slices [items] into safe chunks below SQLite's variable limit (default 250).
  static Future<void> batchChunked<T>(
    List<T> items, {
    int chunkSize = 250,
    required Future<void> Function(List<T> chunk) action,
  }) async {
    for (var i = 0; i < items.length; i += chunkSize) {
      final end = (i + chunkSize < items.length) ? i + chunkSize : items.length;
      await action(items.sublist(i, end));
    }
  }

  bool _closed = false;

  /// Closes database connections.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _outboxRepo.close();
  }
}
