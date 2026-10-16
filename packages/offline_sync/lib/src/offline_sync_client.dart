import 'dart:async';
import 'package:sqlite3/sqlite3.dart' show ResultSet, Row;
import 'uuid_v7.dart';
import 'sync_storage.dart';
import 'sync_worker.dart';
import 'sync_profile.dart';

/// Top-level developer facade for the offline-first synchronization engine.
class OfflineSyncClient {
  final SyncStorage storage;
  final SyncWorker worker;
  final SyncProfile profile;
  final Map<String, String> _entityUrls = {};
  Timer? _periodicTimer;
  Duration _periodicInterval = const Duration(seconds: 30);
  bool _isPaused = false;
  bool _isSyncing = false;

  OfflineSyncClient._({
    required this.storage,
    required this.worker,
    required this.profile,
  });

  /// Initializes storage, outbox schema, connection pools, and sync worker.
  static Future<OfflineSyncClient> initialize({
    required String databasePath,
    String serverUrl = '',
    SyncProfile profile = SyncProfile.standard,
    int maxReaders = 4,
    int pullPageLimit = 50,
    Map<String, dynamic>? scopeFilter,
    Future<String?> Function()? getAuthToken,
    Future<void> Function()? onAuthExpired,
    String? Function(String entity, Map<String, dynamic> record)? validateInvariants,
    int currentSchemaVersion = 1,
    MutationMigrator? migrator,
    void Function(String message)? onLog,
  }) async {
    final storage = await SyncStorage.open(
      path: databasePath,
      maxReaders: maxReaders,
    );

    final worker = SyncWorker(
      storage: storage,
      serverUrl: serverUrl,
      profile: profile,
      pullPageLimit: pullPageLimit,
      scopeFilter: scopeFilter,
      getAuthToken: getAuthToken,
      onAuthExpired: onAuthExpired,
      validateInvariants: validateInvariants,
      currentSchemaVersion: currentSchemaVersion,
      migrator: migrator,
      onLog: onLog,
    );

    return OfflineSyncClient._(
      storage: storage,
      worker: worker,
      profile: profile,
    );
  }

  /// Registers an entity with its exact remote destination URL.
  Future<void> registerEntity(
    String entityName, {
    required String url,
    Map<String, String> columnTypes = const {},
    String? foreignKeyClause,
  }) async {
    _entityUrls[entityName] = url;
    await storage.registerEntityTable(
      entityName,
      columnTypes,
      foreignKeyClause: foreignKeyClause,
    );
  }

  /// Registers an entity table with custom columns, optional foreign keys, and optional full destination URL.
  Future<void> registerTable(
    String entityName,
    Map<String, String> columnTypes, {
    String? foreignKeyClause,
    String? url,
  }) async {
    if (url != null) _entityUrls[entityName] = url;
    await storage.registerEntityTable(
      entityName,
      columnTypes,
      foreignKeyClause: foreignKeyClause,
    );
  }

  /// Atomically commits an optimistic entity write and appends to the outbox.
  /// If [id] is omitted, it will use `data['id']` or generate a monotonic UUIDv7.
  /// If [url] is provided, it overrides any registered entity destination URL.
  Future<String> save({
    required String entity,
    String? id,
    required Map<String, dynamic> data,
    int version = 1,
    String? dependsOnMutationId,
    int schemaVersion = 1,
    String? url,
    String? httpMethod,
  }) async {
    final effectiveId = id ?? (data['id'] as String?) ?? UuidV7.generate();
    final effectiveUrl = url ?? _entityUrls[entity];
    return await storage.save(
      entity: entity,
      id: effectiveId,
      data: data,
      version: version,
      dependsOnMutationId: dependsOnMutationId,
      schemaVersion: schemaVersion,
      endpointUrl: effectiveUrl,
      httpMethod: httpMethod,
    );
  }

  /// Friendly alias for [save]. Stores a record locally in backup storage,
  /// queues it for remote sync, and returns the record's primary key [id].
  Future<String> store(
    String entity,
    Map<String, dynamic> data, {
    String? id,
    String? url,
    String? httpMethod,
  }) async {
    final effectiveId = id ?? (data['id'] as String?) ?? UuidV7.generate();
    await save(
      entity: entity,
      id: effectiveId,
      data: data,
      url: url,
      httpMethod: httpMethod,
    );
    return effectiveId;
  }

  /// Atomically deletes an entity and appends a delete envelope to the outbox.
  Future<String> delete({
    required String entity,
    required String id,
    String? url,
    String? httpMethod,
  }) async {
    final effectiveUrl = url ?? _entityUrls[entity];
    return await storage.delete(
      entity: entity,
      id: id,
      endpointUrl: effectiveUrl,
      httpMethod: httpMethod,
    );
  }

  /// Restores records from local offline storage. Works 100% offline.
  Future<List<Row>> restore(
    String entity, {
    String? where,
    List<dynamic> whereArgs = const [],
    String? orderBy,
  }) async {
    var sql = 'SELECT * FROM $entity';
    if (where != null) sql += ' WHERE $where';
    if (orderBy != null) sql += ' ORDER BY $orderBy';
    return await query(sql, whereArgs);
  }

  /// Restores a single record by ID from local offline storage. Works 100% offline.
  Future<Row?> restoreById(String entity, String id) async {
    final rows = await query('SELECT * FROM $entity WHERE id = ? LIMIT 1', [id]);
    return rows.isEmpty ? null : rows.first;
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

  /// Starts automatic periodic background syncing with profile-aware defaults.
  void startPeriodicSync({Duration? interval}) {
    final defaultInterval = profile == SyncProfile.basic
        ? const Duration(seconds: 60)
        : profile == SyncProfile.standard
            ? const Duration(seconds: 30)
            : const Duration(seconds: 15);
    _periodicInterval = interval ?? defaultInterval;
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

  /// Listens to [isOnlineStream] and automatically triggers [sync] upon reconnection.
  StreamSubscription<bool> attachConnectivity(Stream<bool> isOnlineStream) {
    return isOnlineStream.listen((isOnline) {
      if (isOnline && !_isPaused) {
        sync();
      }
    });
  }

  /// Live reactive stream of all mutations that encountered errors during sync
  /// (e.g. poison pills, validation rejections, or DLQ quarantine).
  Stream<ResultSet> watchFailedMutations() {
    return watch(
      "SELECT * FROM _sync_outbox WHERE status IN ('failed', 'dlq', 'validation_error') ORDER BY created_at DESC",
    );
  }

  /// Returns all currently failed or quarantined mutations from the outbox.
  Future<List<Row>> getFailedMutations() async {
    return query(
      "SELECT * FROM _sync_outbox WHERE status IN ('failed', 'dlq', 'validation_error') ORDER BY created_at DESC",
    );
  }

  /// Closes database connections and stops periodic timers.
  Future<void> close() async {
    _periodicTimer?.cancel();
    _periodicTimer = null;
    await storage.close();
  }
}

/// Friendly alias for [OfflineSyncClient].
typedef OrbitClient = OfflineSyncClient;
