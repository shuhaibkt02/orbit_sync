import 'dart:async';
import 'package:sqlite3/sqlite3.dart' show ResultSet, Row;
import 'uuid_v7.dart';
import 'sync_storage.dart';
import 'sync_worker.dart';

/// Top-level developer facade for the offline-first synchronization engine.
class OfflineSyncClient {
  final SyncStorage storage;
  final SyncWorker worker;
  Timer? _periodicTimer;
  Duration _periodicInterval = const Duration(seconds: 30);
  bool _isPaused = false;
  bool _isSyncing = false;

  OfflineSyncClient._({
    required this.storage,
    required this.worker,
  });

  /// Initializes storage, outbox schema, connection pools, and sync worker.
  static Future<OfflineSyncClient> initialize({
    required String databasePath,
    required String serverUrl,
    int maxReaders = 4,
    int pullPageLimit = 50,
    Map<String, dynamic>? scopeFilter,
    Future<String?> Function()? getAuthToken,
    Future<void> Function()? onAuthExpired,
    String? Function(String entity, Map<String, dynamic> record)? validateInvariants,
    int currentSchemaVersion = 1,
    MutationMigrator? migrator,
  }) async {
    final storage = await SyncStorage.open(
      path: databasePath,
      maxReaders: maxReaders,
    );

    final worker = SyncWorker(
      storage: storage,
      serverUrl: serverUrl,
      pullPageLimit: pullPageLimit,
      scopeFilter: scopeFilter,
      getAuthToken: getAuthToken,
      onAuthExpired: onAuthExpired,
      validateInvariants: validateInvariants,
      currentSchemaVersion: currentSchemaVersion,
      migrator: migrator,
    );

    return OfflineSyncClient._(
      storage: storage,
      worker: worker,
    );
  }

  /// Registers an entity table with custom columns and optional foreign keys.
  Future<void> registerTable(
    String entityName,
    Map<String, String> columnTypes, {
    String? foreignKeyClause,
  }) async {
    await storage.registerEntityTable(
      entityName,
      columnTypes,
      foreignKeyClause: foreignKeyClause,
    );
  }

  /// Atomically commits an optimistic entity write and appends to the outbox.
  /// If [id] is omitted, it will use `data['id']` or generate a monotonic UUIDv7.
  Future<String> save({
    required String entity,
    String? id,
    required Map<String, dynamic> data,
    int version = 1,
    String? dependsOnMutationId,
    int schemaVersion = 1,
  }) async {
    final effectiveId = id ?? (data['id'] as String?) ?? UuidV7.generate();
    return await storage.save(
      entity: entity,
      id: effectiveId,
      data: data,
      version: version,
      dependsOnMutationId: dependsOnMutationId,
      schemaVersion: schemaVersion,
    );
  }

  /// Atomically deletes an entity and appends a delete envelope to the outbox.
  Future<String> delete({
    required String entity,
    required String id,
  }) async {
    return await storage.delete(
      entity: entity,
      id: id,
    );
  }

  /// Queries records from the local SQLite database via pooled readers.
  Future<List<Row>> query(String query, [List<dynamic> parameters = const []]) async {
    return await storage.db.getAll(query, parameters);
  }

  /// Watches query updates reactively with zero codegen.
  Stream<ResultSet> watch(String query, {List<dynamic> parameters = const []}) {
    return storage.watch(query, parameters: parameters);
  }

  /// Performs a full bidirectional sync: drains pending outbox push, then pulls incoming changes.
  Future<void> sync() async {
    if (_isSyncing || _isPaused) return;
    _isSyncing = true;
    try {
      // 1. Drain pending outbox mutations
      while (true) {
        final pushRes = await worker.pushBatch(batchSize: 20);
        if (pushRes.status != SyncPushStatus.success || pushRes.applied == 0) {
          break;
        }
      }

      // 2. Pull remote delta changes
      await worker.pullAll();
    } finally {
      _isSyncing = false;
    }
  }

  /// Starts automatic periodic background syncing.
  void startPeriodicSync({Duration interval = const Duration(seconds: 30)}) {
    _periodicInterval = interval;
    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(_periodicInterval, (_) {
      if (!_isPaused) {
        sync();
      }
    });
  }

  /// Pauses automatic sync (useful when app minimizes to background).
  void pauseSync() {
    _isPaused = true;
  }

  /// Resumes automatic sync (useful when app returns to foreground).
  void resumeSync() {
    _isPaused = false;
    // Trigger immediate sync on foreground return
    sync();
  }

  bool get isPaused => _isPaused;

  /// Closes database connections and stops periodic timers.
  Future<void> close() async {
    _periodicTimer?.cancel();
    _periodicTimer = null;
    await storage.close();
  }
}
