import 'dart:async';
import 'dart:io';
import 'package:sqlite3/sqlite3.dart' show ResultSet;
import 'package:sqlite_async/sqlite_async.dart';

import 'storage_recovery.dart';
import 'storage_schema.dart';
import 'id_map_repository.dart';
import 'baseline_manager.dart';
import 'outbox_writer.dart';
import 'outbox_deleter.dart';
import 'cache_cleaner.dart';

export 'sync_validator.dart';
export 'storage_recovery.dart';
export 'storage_schema.dart';
export 'id_map_repository.dart';
export 'baseline_manager.dart';
export 'outbox_writer.dart';
export 'outbox_deleter.dart';
export 'cache_cleaner.dart';

/// Clean coordinator facade managing local SQLite storage, WAL pooling,
/// transactional outbox, shadow baselines, and reactive query streams.
class SyncStorage {
  final SqliteDatabase db;
  final String path;
  final Set<String> _knownColumns = <String>{};
  late final IdMapRepository _idMapRepo;

  SyncStorage._(this.db, this.path) {
    _idMapRepo = IdMapRepository(db);
  }

  /// Opens or creates database at [path] with connection pooling.
  /// If disk corruption is detected, quarantines damaged files and opens a clean database.
  static Future<SyncStorage> open({
    required String path,
    int maxReaders = 4,
    void Function(String corruptPath)? onDatabaseCorrupted,
    Future<bool> Function(String path)? backupShield,
    Future<String?> Function(String key)? secureStorageReader,
    Future<void> Function(String key, String value)? secureStorageWriter,
    void Function(String sqliteId, String secureId)? onTimeTravelBackupDetected,
  }) async {
    // 1. Invoke host platform backup exclusion shield if provided
    if (backupShield != null && path != ':memory:') {
      try {
        await backupShield(path);
      } catch (_) {}
    }

    // 2. Proactive header check for pre-existing disk files before isolate spawn
    StorageRecovery.sniffAndQuarantineIfCorrupted(path, onDatabaseCorrupted);

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
      StorageRecovery.quarantineCorruptFiles(path, onDatabaseCorrupted);

      db = SqliteDatabase(
        path: path,
        maxReaders: maxReaders,
        options: sqliteOptions,
      );
      await db.initialize();
    }

    final storage = SyncStorage._(db, path);
    await StorageSchema.initSystemSchema(db);

    // 3. Verify installation integrity against cloud backup time-travel bugs
    if (secureStorageReader != null && secureStorageWriter != null) {
      await StorageRecovery.verifyInstallationIntegrity(
        db,
        secureStorageReader: secureStorageReader,
        secureStorageWriter: secureStorageWriter,
        onTimeTravelBackupDetected: onTimeTravelBackupDetected,
      );
    }

    return storage;
  }

  /// Registers an entity table with custom columns and optional foreign key clauses.
  Future<void> registerEntityTable(
    String entityName,
    Map<String, String> columnTypes, {
    String? foreignKeyClause,
  }) {
    return StorageSchema.registerEntityTable(
      db,
      _knownColumns,
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
    return OutboxWriter.save(
      db: db,
      knownColumns: _knownColumns,
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
    return OutboxDeleter.delete(
      db: db,
      knownColumns: _knownColumns,
      entity: entity,
      id: id,
      endpointUrl: endpointUrl,
      httpMethod: httpMethod,
      undoWindow: undoWindow,
    );
  }

  /// Restores a deleted record locally if within its undoWindow.
  Future<bool> undoDelete({required String entity, required String id}) {
    return BaselineManager.undoDelete(db, entity: entity, id: id);
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
    return CacheCleaner.pruneSynced(db, olderThan: olderThan);
  }

  /// Prunes expired local domain cache records where `expires_at < now`.
  Future<int> pruneExpiredCache(String entity) {
    return CacheCleaner.pruneExpiredCache(db, _knownColumns, entity);
  }

  /// Rolls back an optimistic mutation using its stored base snapshot.
  Future<void> rollbackOptimistic(String mutationId, {String status = 'conflict'}) {
    return BaselineManager.rollbackOptimistic(db, mutationId, status: status);
  }

  /// Executes an asynchronous query against SQLite and returns the result set.
  Future<ResultSet> query(String query, [List<dynamic> parameters = const []]) {
    return db.getAll(query, parameters);
  }

  /// Streams reactive updates on any SQL query without requiring codegen TableInfo.
  Stream<ResultSet> watch(String query, {List<dynamic> parameters = const []}) {
    return db.watch(query, parameters: parameters);
  }

  /// Triggers a WAL checkpoint. If [truncate] is true, shrinks WAL file to 0 bytes.
  Future<void> checkpoint({bool truncate = false}) {
    return CacheCleaner.checkpoint(db, truncate: truncate);
  }

  /// Slices [items] into safe chunks below SQLite's variable limit (default 250).
  static Future<void> batchChunked<T>(
    List<T> items, {
    int chunkSize = 250,
    required Future<void> Function(List<T> chunk) action,
  }) {
    return CacheCleaner.batchChunked(items, chunkSize: chunkSize, action: action);
  }

  bool _closed = false;

  /// Closes database connections.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await db.close();
  }
}
