import 'dart:async';
import 'dart:io';
import 'package:sqlite3/sqlite3.dart' show ResultSet;
import 'package:sqlite_async/sqlite_async.dart';

import 'domain/interfaces/i_outbox_repository.dart';
import 'domain/interfaces/i_id_map_repository.dart';
import 'domain/interfaces/i_storage_recovery.dart';
import 'infrastructure/sqlite/sqlite_schema.dart';
import 'infrastructure/sqlite/sqlite_recovery.dart';
import 'infrastructure/sqlite/sqlite_outbox_repository.dart';
import 'infrastructure/sqlite/sqlite_id_map_repository.dart';

export 'domain/models/outbox_mutation.dart';
export 'domain/models/id_mapping.dart';
export 'domain/validation/sync_validator.dart';
export 'domain/interfaces/i_outbox_repository.dart';
export 'domain/interfaces/i_id_map_repository.dart';
export 'domain/interfaces/i_storage_recovery.dart';
export 'infrastructure/uuid/uuid_v7.dart';
export 'infrastructure/sqlite/sqlite_schema.dart';
export 'infrastructure/sqlite/sqlite_recovery.dart';
export 'infrastructure/sqlite/sqlite_outbox_repository.dart';
export 'infrastructure/sqlite/sqlite_id_map_repository.dart';

/// Clean coordinator facade following SOLID & Clean Architecture.
/// Injects domain repository interfaces, manages lifecycle, and provides 0ms local operations.
class SyncStorage {
  final SqliteDatabase db;
  final String path;
  final IOutboxRepository _outboxRepo;
  final IIdMapRepository _idMapRepo;

  SyncStorage._({
    required this.db,
    required this.path,
    required IOutboxRepository outboxRepo,
    required IIdMapRepository idMapRepo,
  })  : _outboxRepo = outboxRepo,
        _idMapRepo = idMapRepo;

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
  }) async {
    // 1. Invoke host platform backup exclusion shield if provided
    if (backupShield != null && path != ':memory:') {
      try {
        await backupShield(path);
      } catch (_) {}
    }

    // 2. Proactive header check before isolate spawn
    recovery.sniffAndQuarantineIfCorrupted(path, onDatabaseCorrupted);

    const sqliteOptions = SqliteOptions(
      journalMode: SqliteJournalMode.wal,
      journalSizeLimit: 67108864, // 64 MB
      lockTimeout: Duration(seconds: 30),
    );

    SqliteDatabase db = SqliteDatabase(
      path: path,
      maxReaders: maxReaders,
      options: sqliteOptions,
    );

    bool deepCorrupt = false;
    try {
      await db.initialize();
      if (path != ':memory:' && File(path).existsSync()) {
        final check = await db.get('PRAGMA quick_check(1);');
        final status = check.values.first?.toString().toLowerCase();
        if (status != 'ok') {
          deepCorrupt = true;
        }
      }
    } catch (_) {
      deepCorrupt = true;
    }

    if (deepCorrupt && path != ':memory:') {
      try {
        await db.close();
      } catch (_) {}
      recovery.quarantineCorruptFiles(path, onDatabaseCorrupted);

      db = SqliteDatabase(
        path: path,
        maxReaders: maxReaders,
        options: sqliteOptions,
      );
      await db.initialize();
    }

    await SqliteSchema.initSystemSchema(db);

    // 3. Verify installation integrity against cloud backup time-travel bugs
    if (secureStorageReader != null && secureStorageWriter != null) {
      await recovery.verifyInstallationIntegrity(
        db,
        secureStorageReader: secureStorageReader,
        secureStorageWriter: secureStorageWriter,
        onTimeTravelBackupDetected: onTimeTravelBackupDetected,
      );
    }

    final outboxRepo = SqliteOutboxRepository(db);
    final idMapRepo = SqliteIdMapRepository(db);

    return SyncStorage._(
      db: db,
      path: path,
      outboxRepo: outboxRepo,
      idMapRepo: idMapRepo,
    );
  }

  /// Registers an entity table with custom columns and optional foreign key clauses.
  Future<void> registerEntityTable(
    String entityName,
    Map<String, String> columnTypes, {
    String? foreignKeyClause,
  }) {
    return _outboxRepo.registerEntityTable(
      entityName,
      columnTypes,
      foreignKeyClause: foreignKeyClause,
    );
  }

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
  }) {
    return _outboxRepo.save(
      entity: entity,
      id: id,
      data: data,
      version: version,
      dependsOnMutationId: dependsOnMutationId,
      schemaVersion: schemaVersion,
      endpointUrl: endpointUrl,
      httpMethod: httpMethod,
      holdFor: holdFor,
      sla: sla,
      ttl: ttl,
      priority: priority,
      correlationTag: correlationTag,
    );
  }

  /// Atomically marks domain entity deleted and appends delete envelope to outbox.
  Future<String?> delete({
    required String entity,
    required String id,
    String? endpointUrl,
    String? httpMethod,
    Duration? undoWindow,
  }) {
    return _outboxRepo.delete(
      entity: entity,
      id: id,
      endpointUrl: endpointUrl,
      httpMethod: httpMethod,
      undoWindow: undoWindow,
    );
  }

  /// Restores a deleted record locally if within its undoWindow.
  Future<bool> undoDelete({required String entity, required String id}) {
    return _outboxRepo.undoDelete(entity: entity, id: id);
  }

  /// Records a local temporary ID to canonical server ID mapping.
  Future<void> registerServerId({
    required String entity,
    required String localTempId,
    required String canonicalServerId,
  }) {
    return _idMapRepo.registerServerId(
      entity: entity,
      localTempId: localTempId,
      canonicalServerId: canonicalServerId,
    );
  }

  /// Resolves the canonical server ID for a local temporary ID.
  Future<String?> getCanonicalServerId({
    required String entity,
    required String localTempId,
  }) {
    return _idMapRepo.getCanonicalServerId(
      entity: entity,
      localTempId: localTempId,
    );
  }

  /// Resolves the local temporary ID for a canonical server ID.
  Future<String?> getLocalTempId({
    required String entity,
    required String canonicalServerId,
  }) {
    return _idMapRepo.getLocalTempId(
      entity: entity,
      canonicalServerId: canonicalServerId,
    );
  }

  /// Prunes completed synced outbox records older than [olderThan].
  Future<int> pruneSynced({Duration olderThan = const Duration(days: 7)}) {
    return _outboxRepo.pruneSynced(olderThan: olderThan);
  }

  /// Prunes expired local domain cache records where `expires_at < now`.
  Future<int> pruneExpiredCache(String entity) {
    return _outboxRepo.pruneExpiredCache(entity);
  }

  /// Rolls back an optimistic mutation using its stored base snapshot.
  Future<void> rollbackOptimistic(String mutationId, {String status = 'conflict'}) {
    return _outboxRepo.rollbackOptimistic(mutationId, status: status);
  }

  /// Executes an asynchronous query against SQLite and returns the result set.
  Future<ResultSet> query(String query, [List<dynamic> parameters = const []]) {
    return _outboxRepo.query(query, parameters);
  }

  /// Streams reactive updates on any SQL query without requiring codegen TableInfo.
  Stream<ResultSet> watch(String query, {List<dynamic> parameters = const []}) {
    return _outboxRepo.watch(query, parameters: parameters);
  }

  /// Triggers a WAL checkpoint. If [truncate] is true, shrinks WAL file to 0 bytes.
  Future<void> checkpoint({bool truncate = false}) {
    return _outboxRepo.checkpoint(truncate: truncate);
  }

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
