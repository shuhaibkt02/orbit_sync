import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:sqlite3/sqlite3.dart' show ResultSet, Row;
import 'uuid_v7.dart';
import 'sync_storage.dart';
import 'sync_worker.dart';
import 'sync_profile.dart';
import 'connectivity_monitor.dart';
import 'sync_failure.dart';

/// Top-level developer facade for the offline-first synchronization engine.
class OfflineSyncClient {
  final SyncStorage storage;
  final SyncWorker worker;
  final SyncProfile profile;
  final ConnectivityMonitor connectivity;
  final Map<String, String> _entityUrls = {};
  Timer? _periodicTimer;
  Duration _periodicInterval = const Duration(seconds: 30);
  bool _isPaused = false;
  bool _isSyncing = false;

  OfflineSyncClient._({
    required this.storage,
    required this.worker,
    required this.profile,
    required this.connectivity,
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
    String? healthCheckUrl,
    Duration connectivityTimeout = const Duration(seconds: 3),
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

    final connectivity = ConnectivityMonitor(
      timeout: connectivityTimeout,
      defaultProbeUrl: healthCheckUrl ?? (serverUrl.isNotEmpty ? serverUrl : null),
    );

    final client = OfflineSyncClient._(
      storage: storage,
      worker: worker,
      profile: profile,
      connectivity: connectivity,
    );

    // Auto-sync the exact moment signal is restored
    connectivity.onConnectivityChanged.listen((isOnline) {
      if (isOnline && !client.isPaused) {
        client.sync();
      }
    });

    return client;
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

  /// Returns typed [SyncFailure] objects with status code, message, and URL for all failed mutations.
  Future<List<SyncFailure>> getFailures() async {
    final rows = await getFailedMutations();
    return rows.map(SyncFailure.fromRow).toList();
  }

  /// Live reactive stream of typed [SyncFailure] objects for Flutter UI warning banners.
  Stream<List<SyncFailure>> watchFailures() {
    return watchFailedMutations().map((rs) => rs.map(SyncFailure.fromRow).toList());
  }

  /// Hydrates local offline storage from a standard remote REST API endpoint.
  /// Does NOT enqueue outbox sync mutations, as this data originates from the remote server.
  Future<int> fetchAndStore(
    String entity, {
    required String url,
    Map<String, String>? headers,
  }) async {
    final req = await worker.httpClient.openUrl('GET', Uri.parse(url));
    req.headers.contentType = ContentType.json;
    if (worker.getAuthToken != null) {
      final token = await worker.getAuthToken!();
      if (token != null) req.headers.set('Authorization', 'Bearer $token');
    }
    if (headers != null) {
      headers.forEach(req.headers.set);
    }
    final resp = await req.close();
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpException('Failed to hydrate $entity from $url: HTTP ${resp.statusCode}');
    }
    final bodyStr = await utf8.decoder.bind(resp).join();
    final decoded = jsonDecode(bodyStr);
    final List<dynamic> items = decoded is List ? decoded : (decoded['data'] as List? ?? []);

    int count = 0;
    for (final item in items) {
      if (item is Map<String, dynamic>) {
        final id = (item['id'] as String?) ?? UuidV7.generate();
        await storage.db.writeTransaction((tx) async {
          final now = DateTime.now().millisecondsSinceEpoch;
          for (final key in item.keys) {
            if (key != 'id' && key != 'version' && key != 'updated_at' && key != '_base_snapshot_json') {
              try {
                await tx.execute('ALTER TABLE $entity ADD COLUMN $key TEXT');
              } catch (_) {}
            }
          }
          final cols = <String>['id', 'version', 'updated_at'];
          final vals = <dynamic>[id, (item['version'] as int?) ?? 1, now];
          for (final entry in item.entries) {
            if (entry.key != 'id' && entry.key != 'version' && entry.key != 'updated_at') {
              cols.add(entry.key);
              vals.add(entry.value);
            }
          }
          final colStr = cols.join(', ');
          final placeholders = cols.map((_) => '?').join(', ');
          await tx.execute('INSERT OR REPLACE INTO $entity ($colStr) VALUES ($placeholders)', vals);
        });
        count++;
      }
    }
    return count;
  }

  /// Headless sync runner for OS background schedulers (WorkManager, AlarmManager, BGAppRefreshTask).
  static Future<void> headlessSync({
    required String databasePath,
    Future<String?> Function()? getAuthToken,
    void Function(String message)? onLog,
  }) async {
    final client = await OfflineSyncClient.initialize(
      databasePath: databasePath,
      getAuthToken: getAuthToken,
      onLog: onLog,
    );
    try {
      await client.sync();
    } finally {
      await client.close();
    }
  }

  /// Closes database connections, connectivity monitors, and stops periodic timers.
  Future<void> close() async {
    _periodicTimer?.cancel();
    _periodicTimer = null;
    connectivity.dispose();
    await storage.close();
  }
}

/// Friendly alias for [OfflineSyncClient].
typedef OrbitClient = OfflineSyncClient;
