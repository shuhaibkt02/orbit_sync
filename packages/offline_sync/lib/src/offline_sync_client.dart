import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart' show ResultSet, Row;
import 'storage/sync_storage.dart';
import 'sync_worker.dart';
import 'sync_profile.dart';
import 'sync_transport.dart';
import 'http_sync_transport.dart';
import 'connectivity_monitor.dart';
import 'sync_failure.dart';
import 'sync_status_summary.dart';

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
    SyncTransport? transport,
    SyncProfile profile = SyncProfile.standard,
    http.Client? httpClient,
    BackoffPolicy? backoffPolicy,
    int Function()? nowMsProvider,
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
    Future<bool> Function()? reachabilityChecker,
  }) async {
    final storage = await SyncStorage.open(
      path: databasePath,
      maxReaders: maxReaders,
    );

    final worker = SyncWorker(
      storage: storage,
      serverUrl: serverUrl,
      transport: transport,
      profile: profile,
      client: httpClient,
      backoffPolicy: backoffPolicy,
      nowMsProvider: nowMsProvider,
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
      reachabilityChecker: reachabilityChecker,
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
    Duration? holdFor,
    Duration? sla,
    Duration? ttl,
    int priority = 0,
    String? correlationTag,
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
      holdFor: holdFor,
      sla: sla,
      ttl: ttl,
      priority: priority,
      correlationTag: correlationTag,
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
    Duration? holdFor,
    Duration? sla,
    Duration? ttl,
    int priority = 0,
    String? correlationTag,
  }) async {
    final effectiveId = id ?? (data['id'] as String?) ?? UuidV7.generate();
    await save(
      entity: entity,
      id: effectiveId,
      data: data,
      url: url,
      httpMethod: httpMethod,
      holdFor: holdFor,
      sla: sla,
      ttl: ttl,
      priority: priority,
      correlationTag: correlationTag,
    );
    return effectiveId;
  }

  /// Prunes expired clean records from the local cache table [entity].
  /// Guarantees that dirty records with pending outbox mutations are never deleted.
  Future<int> pruneExpiredCache(String entity) async {
    return await storage.pruneExpiredCache(entity);
  }

  /// Atomically deletes an entity and appends a delete envelope to the outbox.
  /// If [undoWindow] is passed, the deletion can be reversed locally via [undoDelete].
  Future<String?> delete({
    required String entity,
    required String id,
    String? url,
    String? httpMethod,
    Duration? undoWindow,
  }) async {
    final effectiveUrl = url ?? _entityUrls[entity];
    return await storage.delete(
      entity: entity,
      id: id,
      endpointUrl: effectiveUrl,
      httpMethod: httpMethod,
      undoWindow: undoWindow,
    );
  }

  /// Reverses an un-synced deletion during its [undoWindow].
  Future<bool> undoDelete({
    required String entity,
    required String id,
  }) async {
    return await storage.undoDelete(entity: entity, id: id);
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

  /// Performs a full bidirectional sync: pulls incoming changes, then drains pending outbox push.
  /// If [force] is true, pending mutations are pushed immediately bypassing any active backoff window.
  Future<void> sync({bool force = false}) async {
    if (_isSyncing || _isPaused) return;
    _isSyncing = true;
    try {
      // 1. Pull remote delta changes first (resolve remote changes & deletions before pushing)
      if (worker.serverUrl.isNotEmpty || worker.transport is! HttpSyncTransport) {
        await worker.pullAll();
      }

      // 2. Drain pending outbox mutations
      while (true) {
        final pushRes = await worker.pushBatch(batchSize: 20, force: force);
        if (pushRes.status != SyncPushStatus.success || pushRes.applied == 0) {
          break;
        }
      }
    } finally {
      _isSyncing = false;
    }
  }

  /// Notifies the sync engine that the host application was resumed from the background.
  /// Bypasses the 3-second flap guard, immediately checks reachability, and triggers sync.
  Future<void> notifyAppResumed() async {
    await connectivity.notifyAppResumed();
    if (connectivity.isOnline && !_isPaused) {
      await sync();
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

  /// Returns high-level outbox sync metrics (pending, in-flight, synced, failed) without writing SQL.
  Future<SyncStatusSummary> getSummary() async {
    final rows = await query(
      "SELECT status, COUNT(*) as cnt, MIN(created_at) as oldest FROM _sync_outbox GROUP BY status",
    );
    return _buildSummaryFromRows(rows);
  }

  /// Live reactive stream of outbox sync metrics for dashboards and status widgets with zero SQL.
  Stream<SyncStatusSummary> watchSummary() {
    return watch(
      "SELECT status, COUNT(*) as cnt, MIN(created_at) as oldest FROM _sync_outbox GROUP BY status",
    ).map(_buildSummaryFromRows);
  }

  static SyncStatusSummary _buildSummaryFromRows(Iterable<Row> rows) {
    int pending = 0;
    int inFlight = 0;
    int synced = 0;
    int failed = 0;
    int total = 0;
    int? oldestPendingEpoch;

    for (final r in rows) {
      final status = r['status'] as String?;
      final count = (r['cnt'] as int?) ?? 0;
      final oldest = r['oldest'] as int?;
      total += count;

      if (status == 'pending') {
        pending += count;
        if (oldest != null && (oldestPendingEpoch == null || oldest < oldestPendingEpoch)) {
          oldestPendingEpoch = oldest;
        }
      } else if (status == 'in_flight') {
        inFlight += count;
        if (oldest != null && (oldestPendingEpoch == null || oldest < oldestPendingEpoch)) {
          oldestPendingEpoch = oldest;
        }
      } else if (status == 'synced') {
        synced += count;
      } else if (status == 'failed' || status == 'dlq' || status == 'validation_error') {
        failed += count;
        if (oldest != null && (oldestPendingEpoch == null || oldest < oldestPendingEpoch)) {
          oldestPendingEpoch = oldest;
        }
      }
    }

    return SyncStatusSummary(
      pending: pending,
      inFlight: inFlight,
      synced: synced,
      failed: failed,
      total: total,
      oldestPendingAt: oldestPendingEpoch != null
          ? DateTime.fromMillisecondsSinceEpoch(oldestPendingEpoch)
          : null,
    );
  }

  /// Returns typed [OutboxRecord] objects optionally filtered by [status] with zero SQL.
  Future<List<OutboxRecord>> getRecords({String? status, int limit = 100}) async {
    String sql = 'SELECT * FROM _sync_outbox';
    final params = <dynamic>[];
    if (status != null) {
      sql += ' WHERE status = ?';
      params.add(status);
    }
    sql += ' ORDER BY created_at DESC LIMIT ?';
    params.add(limit);
    final rows = await query(sql, params);
    return rows.map(OutboxRecord.fromRow).toList();
  }

  /// Live reactive stream of typed [OutboxRecord] objects optionally filtered by [status].
  Stream<List<OutboxRecord>> watchRecords({String? status, int limit = 100}) {
    String sql = 'SELECT * FROM _sync_outbox';
    final params = <dynamic>[];
    if (status != null) {
      sql += ' WHERE status = ?';
      params.add(status);
    }
    sql += ' ORDER BY created_at DESC LIMIT ?';
    params.add(limit);
    return watch(sql, parameters: params).map((rs) => rs.map(OutboxRecord.fromRow).toList());
  }

  /// Returns unsynced mutations that have exceeded [maxAge] (e.g. 60 minutes) without writing SQL.
  Future<List<OutboxRecord>> getStaleRecords({required Duration maxAge}) async {
    final cutoff = DateTime.now().millisecondsSinceEpoch - maxAge.inMilliseconds;
    final rows = await query(
      "SELECT * FROM _sync_outbox WHERE status NOT IN ('synced') AND created_at <= ? ORDER BY created_at ASC",
      [cutoff],
    );
    return rows.map(OutboxRecord.fromRow).toList();
  }

  /// Live reactive stream of unsynced mutations exceeding [maxAge] for business SLA escalation alerts.
  Stream<List<OutboxRecord>> watchStaleRecords({required Duration maxAge}) {
    return watch(
      "SELECT * FROM _sync_outbox WHERE status NOT IN ('synced') ORDER BY created_at ASC",
    ).map((rs) => rs.map(OutboxRecord.fromRow).where((r) => r.isStale(maxAge)).toList());
  }

  /// Manually resets a failed or quarantined mutation to 'pending' for immediate re-sync.
  Future<void> retryMutation(String mutationId, {bool syncNow = false}) async {
    await storage.db.execute(
      "UPDATE _sync_outbox SET status = 'pending', retry_count = 0, next_retry_at = NULL WHERE mutation_id = ?",
      [mutationId],
    );
    if (syncNow) {
      await sync(force: true);
    }
  }

  /// Manually resets all failed, quarantined (DLQ), and validation-error mutations to 'pending'.
  Future<void> retryAllFailed({bool syncNow = false}) async {
    await storage.db.execute(
      "UPDATE _sync_outbox SET status = 'pending', retry_count = 0, next_retry_at = NULL WHERE status IN ('failed', 'dlq', 'validation_error')",
    );
    if (syncNow) {
      await sync(force: true);
    }
  }

  /// Cancels and deletes an unsynced mutation from the outbox so it is never pushed.
  Future<void> cancelMutation(String mutationId) async {
    await storage.db.execute(
      "DELETE FROM _sync_outbox WHERE mutation_id = ?",
      [mutationId],
    );
  }

  /// Manually marks a mutation as synced when the developer handles delivery via a custom endpoint.
  Future<void> markSynced(String mutationId) async {
    await storage.db.execute(
      "UPDATE _sync_outbox SET status = 'synced', next_retry_at = NULL WHERE mutation_id = ?",
      [mutationId],
    );
  }

  /// Hydrates local offline storage from a standard remote REST API endpoint.
  /// Does NOT enqueue outbox sync mutations, as this data originates from the remote server.
  Future<int> fetchAndStore(
    String entity, {
    required String url,
    Map<String, String>? headers,
  }) async {
    final req = http.Request('GET', Uri.parse(url));
    req.headers['content-type'] = 'application/json';
    if (worker.getAuthToken != null) {
      final token = await worker.getAuthToken!();
      if (token != null) req.headers['authorization'] = 'Bearer $token';
    }
    if (headers != null) {
      req.headers.addAll(headers);
    }
    final client = worker.httpClient ?? http.Client();
    final streamed = await client.send(req);
    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpException('Failed to hydrate $entity from $url: HTTP ${resp.statusCode}');
    }
    final bodyStr = resp.body;
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
