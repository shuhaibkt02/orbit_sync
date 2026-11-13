import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart' show Row, ResultSet;
import '../storage/sync_storage.dart';
import '../consensus/sync_worker.dart';
import '../consensus/domain/models/sync_failure.dart';
import '../consensus/domain/models/sync_status_summary.dart';
import '../sync_profile.dart';
import '../transport/sync_transport.dart';
import '../connectivity/connectivity_monitor.dart';
import '../observability/sync_observer.dart';
import '../observability/domain/models/sync_event.dart';
import '../observability/services/sla_monitor.dart';
import '../observability/services/sync_center.dart';
import '../consensus/domain/models/priority.dart';
import 'domain/models/media_config.dart';
import 'orbit_client.dart';
import 'domain/models/orbit_sync_event.dart';
import 'domain/models/sync_job.dart';
import 'domain/models/rest_endpoints.dart';
import 'domain/models/client_exceptions.dart';
import 'domain/policies/causal_horizon_guard.dart';
import 'domain/policies/sqlite_type_sanitizer.dart';
import 'services/sync_event_bus.dart';
import 'services/sync_coordinator.dart';
import 'services/entity_hydrator.dart';
import 'services/drain_orchestrator.dart';
import 'services/session_manager.dart';
import 'services/orbit_table_impl.dart';
import 'services/dashboard_query_helper.dart';
import 'services/model_registrar.dart';
import 'services/entity_crud_helper.dart';
import 'services/schema_migration_runner.dart';

/// Concrete implementation of the unified application facade (Layer 5).
class OrbitClientImpl implements OrbitClient {
  SyncStorage _storage;
  @override
  SyncStorage get storage => _storage;

  SyncWorker _worker;
  @override
  SyncWorker get worker => _worker;

  @override
  SyncTransport get transport => _transport ?? _worker.transport;

  final SyncProfile profile;
  final ConnectivityMonitor connectivity;
  final Future<String?> Function()? getAuthToken;
  @override
  final String baseUrl;

  String? _currentUserId;
  @override
  String? get currentUserId => _currentUserId;
  @override
  String? get userId => _currentUserId;

  String? _appDir;
  String? get appDir => _appDir;

  final int maxReaders;
  final int currentSchemaVersion;
  final MutationMigrator? migrator;
  final int Function()? nowMsProvider;
  final int pullPageLimit;
  final Map<String, dynamic>? scopeFilter;
  final Future<void> Function()? onAuthExpired;
  final String? Function(String entity, Map<String, dynamic> record)?
      validateInvariants;
  final void Function(String message)? onLog;
  final SyncTransport? _transport;
  final http.Client? httpClient;
  final BackoffPolicy? backoffPolicy;

  final Map<
      String,
      ({
        Map<String, String> columns,
        String? foreignKeyClause,
        String? url
      })> _registeredTables = {};
  final Map<String, String? Function(dynamic json)> _idExtractors = {};
  SlaMonitor? _slaMon;

  final SyncEventBus eventBus = SyncEventBus();
  final SessionManager sessionManager = const SessionManager();
  late CausalHorizonGuard horizonGuard;
  late EntityHydrator hydrator;
  late SyncCoordinator coordinator;
  late DrainOrchestrator drainOrchestrator;
  late DashboardQueryHelper queryHelper;
  late final ModelRegistrar _registrar;
  late EntityCrudHelper _crudHelper;
  @override
  late final SyncObserver observer;
  late OrbitSyncCenter _syncCenter;

  @override
  OrbitSyncCenter get syncCenter => _syncCenter;

  @override
  Future<void> syncNow() => _syncCenter.syncNow();

  @override
  Future<void> retryItem(String mutationId) =>
      _syncCenter.retryItem(mutationId);

  final List<StreamController<dynamic>> _activeWatchControllers = [];
  Timer? _periodicTimer;
  Duration _periodicInterval = const Duration(seconds: 30);
  bool _isPaused = false;

  OrbitClientImpl({
    required SyncStorage storage,
    required SyncWorker worker,
    required this.profile,
    required this.connectivity,
    this.baseUrl = '',
    this.getAuthToken,
    String? appDir,
    String? currentUserId,
    this.maxReaders = 4,
    this.currentSchemaVersion = 1,
    this.migrator,
    this.nowMsProvider,
    this.pullPageLimit = 50,
    this.scopeFilter,
    this.onAuthExpired,
    this.validateInvariants,
    this.onLog,
    SyncTransport? transport,
    this.httpClient,
    this.backoffPolicy,
  })  : _storage = storage,
        _worker = worker,
        _appDir = appDir,
        _currentUserId = currentUserId,
        _transport = transport {
    horizonGuard = CausalHorizonGuard(_storage);
    hydrator = EntityHydrator(storage: _storage);
    _slaMon = SlaMonitor(storage: _storage, nowMsProvider: nowMsProvider)
      ..start();
    queryHelper = DashboardQueryHelper(storage: _storage, watchFn: watch);
    observer = SyncObserver(
      slaMonitor: _slaMon,
      onRetryMutation: (id, {syncNow = false}) async {
        await queryHelper.retryMutation(id);
        if (syncNow) await sync(force: true);
      },
      onRetryAllFailed: ({syncNow = false}) async {
        await queryHelper.retryAllFailed();
        if (syncNow) await sync(force: true);
      },
    );
    coordinator = SyncCoordinator(
        worker: _worker, eventBus: eventBus, onEvent: observer.publish);
    drainOrchestrator = DrainOrchestrator(
        storage: _storage,
        worker: _worker,
        connectivity: connectivity,
        activeWatchControllers: _activeWatchControllers,
        awaitInFlightSync: () async => coordinator.currentInFlightSync);
    final adapter = _worker.transport is HttpSyncTransport
        ? (_worker.transport as HttpSyncTransport).adapter
        : null;
    _registrar = ModelRegistrar(
      storage: _storage,
      baseUrl: baseUrl,
      getAuthToken: getAuthToken,
      httpClient: _worker.httpClient,
      adapter: adapter,
      connectivity: connectivity,
    );
    _crudHelper = EntityCrudHelper(
        storage: _storage,
        observer: observer,
        isClosed: () => drainOrchestrator.isClosed);
    _syncCenter = OrbitSyncCenterImpl(
      storage: _storage,
      syncNowFn: () => sync(force: true),
      nowMsProvider: nowMsProvider,
    );

    connectivity.onConnectivityChanged.listen((on) => observer.publish(on
        ? OnlineEvent(timestamp: DateTime.now().toUtc())
        : OfflineEvent(timestamp: DateTime.now().toUtc())));
    connectivity.onProbeTimeout = (t, ep) => observer.publish(ProbeTimeoutEvent(
        timestamp: DateTime.now().toUtc(),
        targetUrl: ep,
        latencyMs: t.inMilliseconds));
    final origAuth = _worker.onAuthExpired;
    _worker.onAuthExpired = () async {
      observer.publish(AuthExpiredEvent(timestamp: DateTime.now().toUtc()));
      await origAuth?.call();
    };
  }

  @override
  Stream<OrbitSyncEvent> get syncEvents => eventBus.stream;
  bool get isPaused => _isPaused;
  bool get isClosed => drainOrchestrator.isClosed;

  @override
  OrbitTable<T> collection<T>({
    required String name,
    required T Function(Map<String, dynamic> json) fromJson,
    required Map<String, dynamic> Function(T item) toJson,
    dynamic endpoint,
    String? path,
    HttpMethod createMethod = HttpMethod.post,
    String? createEndpoint,
    String? createPath,
    HttpMethod updateMethod = HttpMethod.put,
    String? updateEndpoint,
    String? updatePath,
    HttpMethod deleteMethod = HttpMethod.delete,
    String? deleteEndpoint,
    String? deletePath,
    String? listEndpoint,
    String? listPath,
    HttpMethod listMethod = HttpMethod.get,
    List<Map<String, dynamic>> Function(dynamic json)? unwrapList,
    String primaryKey = 'id',
    List<String> indexes = const [],
    List<String> foreignKeys = const [],
    Map<String, String> columns = const {},
    RestEndpoints<T>? endpoints,
    RestEndpoint? restEndpoint,
    Duration? cacheTtl,
    Priority? priority,
    Duration? sla,
    Duration? coolingTime,
    MediaConfig? media,
    int? maxCacheRecords,
    Map<String, String>? headers,
    FutureOr<Map<String, String>> Function()? dynamicHeaders,
    Map<String, String> Function()? queryParams,
    String? Function(dynamic json)? idExtractor,
  }) {
    final effectiveEp = endpoint is RestEndpoint
        ? endpoint.path
        : (endpoint?.toString() ?? path ?? '/$name');
    _crudHelper.entityUrls[name] = effectiveEp;
    if (idExtractor != null) {
      _idExtractors[name] = idExtractor;
      _worker.registerIdExtractor(name, idExtractor);
    }
    return _registrar.register<T>(
      name: name,
      fromJson: fromJson,
      toJson: toJson,
      endpoint: endpoint,
      path: path,
      createMethod: createMethod,
      createEndpoint: createEndpoint,
      createPath: createPath,
      updateMethod: updateMethod,
      updateEndpoint: updateEndpoint,
      updatePath: updatePath,
      deleteMethod: deleteMethod,
      deleteEndpoint: deleteEndpoint,
      deletePath: deletePath,
      listEndpoint: listEndpoint,
      listPath: listPath,
      listMethod: listMethod,
      unwrapList: unwrapList,
      primaryKey: primaryKey,
      indexes: indexes,
      foreignKeys: foreignKeys,
      columns: columns,
      endpoints: endpoints,
      restEndpoint: restEndpoint,
      cacheTtl: cacheTtl,
      priority: priority,
      sla: sla,
      coolingTime: coolingTime,
      media: media,
      maxCacheRecords: maxCacheRecords,
      headers: headers,
      dynamicHeaders: dynamicHeaders,
      queryParams: queryParams,
      idExtractor: idExtractor,
    );
  }

  @override
  OrbitTable<T> registerModel<T>({
    required String name,
    required T Function(Map<String, dynamic> json) fromJson,
    required Map<String, dynamic> Function(T item) toJson,
    dynamic endpoint,
    String? path,
    String primaryKey = 'id',
    List<String> indexes = const [],
    List<String> foreignKeys = const [],
    Map<String, String> columns = const {},
    RestEndpoints<T>? endpoints,
    RestEndpoint? restEndpoint,
    Duration? cacheTtl,
    Priority? priority,
    Duration? sla,
    Duration? coolingTime,
    MediaConfig? media,
    int? maxCacheRecords,
    Map<String, String>? headers,
    FutureOr<Map<String, String>> Function()? dynamicHeaders,
    Map<String, String> Function()? queryParams,
    String? Function(dynamic json)? idExtractor,
  }) =>
      collection<T>(
        name: name,
        fromJson: fromJson,
        toJson: toJson,
        endpoint: endpoint,
        path: path,
        primaryKey: primaryKey,
        indexes: indexes,
        foreignKeys: foreignKeys,
        columns: columns,
        endpoints: endpoints,
        restEndpoint: restEndpoint,
        cacheTtl: cacheTtl,
        priority: priority,
        sla: sla,
        coolingTime: coolingTime,
        media: media,
        maxCacheRecords: maxCacheRecords,
        headers: headers,
        dynamicHeaders: dynamicHeaders,
        queryParams: queryParams,
        idExtractor: idExtractor,
      );

  @override
  OrbitTable<T> registerTypedTable<T>({
    required String name,
    required T Function(Map<String, dynamic> json) fromJson,
    required Map<String, dynamic> Function(T item) toJson,
    dynamic endpoint,
    String? path,
    String primaryKey = 'id',
    List<String> indexes = const [],
    List<String> foreignKeys = const [],
    Map<String, String> columns = const {},
    RestEndpoints<T>? endpoints,
    RestEndpoint? restEndpoint,
    Duration? cacheTtl,
    Priority? priority,
    Duration? sla,
    Duration? coolingTime,
    MediaConfig? media,
    int? maxCacheRecords,
    Map<String, String>? headers,
    FutureOr<Map<String, String>> Function()? dynamicHeaders,
    Map<String, String> Function()? queryParams,
    String? Function(dynamic json)? idExtractor,
  }) =>
      registerModel<T>(
        name: name,
        fromJson: fromJson,
        toJson: toJson,
        endpoint: endpoint,
        path: path,
        primaryKey: primaryKey,
        indexes: indexes,
        foreignKeys: foreignKeys,
        columns: columns,
        endpoints: endpoints,
        restEndpoint: restEndpoint,
        cacheTtl: cacheTtl,
        priority: priority,
        sla: sla,
        coolingTime: coolingTime,
        media: media,
        maxCacheRecords: maxCacheRecords,
        headers: headers,
        dynamicHeaders: dynamicHeaders,
        queryParams: queryParams,
        idExtractor: idExtractor,
      );

  @override
  OrbitTable<T> table<T>(String name) => _registrar.table<T>(name);

  @override
  bool get simulateOffline => connectivity.simulateOffline;

  @override
  set simulateOffline(bool value) => connectivity.simulateOffline = value;

  @override
  bool get isOnline => connectivity.isOnline;

  @override
  Future<void> registerTable(String entityName, Map<String, String> columnTypes,
      {String? foreignKeyClause, String? url}) async {
    _registeredTables[entityName] =
        (columns: columnTypes, foreignKeyClause: foreignKeyClause, url: url);
    await _crudHelper.registerTable(entityName, columnTypes,
        foreignKeyClause: foreignKeyClause, url: url);
  }

  Future<void> registerEntity(String entityName,
          {String? url,
          Map<String, String> columnTypes = const {},
          String? foreignKeyClause}) =>
      registerTable(entityName, columnTypes,
          foreignKeyClause: foreignKeyClause, url: url);

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
    Duration? coolingTime,
    Duration? sla,
    Duration? ttl,
    int priority = 0,
    String? correlationTag,
    Map<String, String>? headers,
    String? authorId,
    String? userId,
    String? mediaPath,
  }) =>
      _crudHelper.save(
        entity: entity,
        id: id,
        data: data,
        version: version,
        dependsOnMutationId: dependsOnMutationId,
        schemaVersion: schemaVersion,
        url: url,
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

  @override
  Future<String> store(
    String entity,
    Map<String, dynamic> data, {
    String? id,
    String? url,
    String? httpMethod,
    Duration? holdFor,
    Duration? coolingTime,
    Duration? sla,
    Duration? ttl,
    int priority = 0,
    String? correlationTag,
    Map<String, String>? headers,
    String? authorId,
    String? userId,
    String? mediaPath,
  }) =>
      _crudHelper.store(
        entity,
        data,
        id: id,
        url: url,
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

  @override
  Future<String?> delete({
    required String entity,
    required String id,
    String? url,
    String? httpMethod,
    Duration? undoWindow,
    Duration? coolingTime,
    Duration? holdFor,
    Map<String, String>? headers,
    String? authorId,
    String? userId,
  }) =>
      _crudHelper.delete(
        entity: entity,
        id: id,
        url: url,
        httpMethod: httpMethod,
        undoWindow: undoWindow,
        coolingTime: coolingTime,
        holdFor: holdFor,
        headers: headers,
        authorId: authorId,
        userId: userId,
      );

  @override
  Future<bool> undoDelete({String? entity, required String id}) =>
      _crudHelper.undoDelete(entity: entity, id: id);
  Future<List<Map<String, dynamic>>> restore(String entity,
          {String? where,
          List<dynamic> whereArgs = const [],
          String? orderBy}) =>
      _crudHelper.restore(entity,
          where: where, whereArgs: whereArgs, orderBy: orderBy);
  Future<Map<String, dynamic>?> restoreById(String entity, String id) =>
      _crudHelper.restoreById(entity, id);

  @override
  Future<List<Row>> query(String query, [List<dynamic> parameters = const []]) {
    if (isClosed) throw const ClientClosedException('query');
    return storage.db
        .getAll(query, const SqliteTypeSanitizer().sanitizeList(parameters));
  }

  @override
  Stream<ResultSet> watch(String query, {List<dynamic> parameters = const []}) {
    if (isClosed) throw const ClientClosedException('watch');
    return storage.watch(query,
        parameters: const SqliteTypeSanitizer().sanitizeList(parameters));
  }

  @override
  SyncJob sync({String? entity, bool force = false, bool pull = false}) =>
      coordinator.triggerSync(
          force: force, isPaused: _isPaused, isClosed: isClosed, pull: pull);
  Future<int> fetchAndStore(String entity,
          {required String url, Map<String, String>? headers}) =>
      hydrator.fetchAndStore(entity,
          url: url, headers: headers, getAuthToken: getAuthToken);

  Future<void> softRejectRecord(String entity, String id,
      {String? reason}) async {
    await horizonGuard.softRejectRecord(
        entity: entity, id: id, errorMessage: reason);
    observer.publish(SyncRejectedEvent(
        timestamp: DateTime.now().toUtc(),
        entity: entity,
        entityId: id,
        errorMessage: reason ?? 'Business rejected'));
  }

  Future<int> holdDescendants(String parentId) async {
    final h = await horizonGuard.holdDescendantMutations(parentId);
    if (h > 0) {
      observer.publish(CascadeFailureEvent(
          timestamp: DateTime.now().toUtc(),
          parentMutationId: parentId,
          childMutationId: 'held-$h'));
    }
    return h;
  }

  void startPeriodicSync({Duration? interval}) {
    _periodicInterval = interval ??
        (profile == SyncProfile.basic
            ? const Duration(seconds: 60)
            : profile == SyncProfile.standard
                ? const Duration(seconds: 30)
                : const Duration(seconds: 15));
    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(_periodicInterval, (_) {
      if (!_isPaused) sync();
    });
  }

  void pauseSync() {
    _isPaused = true;
  }

  void resumeSync() {
    _isPaused = false;
    sync();
  }

  Future<void> notifyAppResumed() async {
    await connectivity.notifyAppResumed();
    if (connectivity.isOnline && !_isPaused) await sync();
  }

  StreamSubscription<bool> attachConnectivity(Stream<bool> isOnline) =>
      isOnline.listen((on) {
        if (on && !_isPaused) sync();
      });

  @override
  Future<SyncStatusSummary> getSummary() => queryHelper.getSummary();
  @override
  Stream<SyncStatusSummary> watchSummary() => queryHelper.watchSummary();
  @override
  Future<List<SyncFailure>> getFailures() => queryHelper.getFailures();
  @override
  Stream<List<SyncFailure>> watchFailures() => queryHelper.watchFailures();
  @override
  Stream<ResultSet> watchFailedMutations() => watch(
      "SELECT * FROM _sync_outbox WHERE status IN ('failed', 'dlq', 'validation_error') ORDER BY created_at DESC");
  @override
  Future<List<Row>> getFailedMutations() => query(
      "SELECT * FROM _sync_outbox WHERE status IN ('failed', 'dlq', 'validation_error') ORDER BY created_at DESC");
  @override
  Future<int> pruneExpiredCache(String entity) async {
    final count = await storage.pruneExpiredCache(entity);
    if (count > 0) {
      observer.publish(DatabasePrunedEvent(
          timestamp: DateTime.now().toUtc(), prunedCount: count));
    }
    return count;
  }

  @override
  Future<int> pruneSyncedOutbox(
          {Duration retention = const Duration(days: 7)}) =>
      storage.pruneSyncedOutbox(retention: retention);
  @override
  Future<List<OutboxRecord>> getRecords({String? status, int limit = 100}) =>
      queryHelper.getRecords(status: status, limit: limit);
  @override
  Stream<List<OutboxRecord>> watchRecords({String? status, int limit = 100}) =>
      queryHelper.watchRecords(status: status, limit: limit);
  @override
  Future<List<OutboxRecord>> getStaleRecords({required Duration maxAge}) =>
      queryHelper.getStaleRecords(maxAge: maxAge);
  @override
  Stream<List<OutboxRecord>> watchStaleRecords({required Duration maxAge}) =>
      queryHelper.watchStaleRecords(maxAge: maxAge);

  @override
  Future<void> retryMutation(String mutationId, {bool syncNow = false}) async {
    await queryHelper.retryMutation(mutationId);
    if (syncNow) await sync(force: true);
  }

  @override
  Future<void> retryAllFailed({bool syncNow = true}) async {
    await queryHelper.retryAllFailed();
    if (syncNow) await sync(force: true);
  }

  @override
  Future<void> cancelMutation(String mutationId) =>
      queryHelper.cancelMutation(mutationId);

  @override
  Future<void> markSynced(String mutationId) =>
      queryHelper.markSynced(mutationId);

  @override
  Future<void> switchUser(String newUserId) async {
    if (isClosed) throw const ClientClosedException('switchUser');
    if (_currentUserId == newUserId) return;

    if (coordinator.isSyncing && coordinator.currentInFlightSync != null) {
      try {
        await coordinator.currentInFlightSync!
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
    }

    _slaMon?.stop();
    await _storage.close();

    final newPath = OrbitClient.resolveDatabasePath(
      appDir: _appDir,
      userId: newUserId,
    );

    final newStorage = await SyncStorage.open(
      path: newPath,
      maxReaders: maxReaders,
    );

    final migrationRunner = SchemaMigrationRunner(
      storage: newStorage,
      targetSchemaVersion: currentSchemaVersion,
      migrator: migrator,
    );
    await migrationRunner.runEagerMigrations();

    _storage = newStorage;
    _currentUserId = newUserId;

    for (final entry in _registeredTables.entries) {
      await newStorage.registerEntityTable(
        entry.key,
        entry.value.columns,
        foreignKeyClause: entry.value.foreignKeyClause,
      );
    }

    await _registrar.updateStorage(newStorage);

    horizonGuard = CausalHorizonGuard(newStorage);
    hydrator = EntityHydrator(storage: newStorage);

    _slaMon = SlaMonitor(
      storage: newStorage,
      checkInterval: const Duration(seconds: 30),
      nowMsProvider: nowMsProvider,
    )..start();
    observer.updateSlaMonitor(_slaMon!);

    queryHelper = DashboardQueryHelper(storage: newStorage, watchFn: watch);
    _crudHelper = EntityCrudHelper(
      storage: newStorage,
      observer: observer,
      isClosed: () => drainOrchestrator.isClosed,
    );
    for (final entry in _registeredTables.entries) {
      if (entry.value.url != null) {
        _crudHelper.entityUrls[entry.key] = entry.value.url!;
      }
    }

    final newWorker = SyncWorker(
      storage: newStorage,
      baseUrl: baseUrl,
      transport: _transport,
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
    for (final entry in _idExtractors.entries) {
      newWorker.registerIdExtractor(entry.key, entry.value);
    }
    final origAuth = newWorker.onAuthExpired;
    newWorker.onAuthExpired = () async {
      observer.publish(AuthExpiredEvent(timestamp: DateTime.now().toUtc()));
      await origAuth?.call();
    };
    _worker = newWorker;

    coordinator = SyncCoordinator(
      worker: newWorker,
      eventBus: eventBus,
      onEvent: observer.publish,
    );

    drainOrchestrator = DrainOrchestrator(
      storage: newStorage,
      worker: newWorker,
      connectivity: connectivity,
      activeWatchControllers: _activeWatchControllers,
      awaitInFlightSync: () async => coordinator.currentInFlightSync,
    );

    await _syncCenter.dispose();
    _syncCenter = OrbitSyncCenterImpl(
      storage: newStorage,
      syncNowFn: () => sync(force: true),
      nowMsProvider: nowMsProvider,
    );
  }

  @override
  Future<void> close(
      {Duration drainTimeout = const Duration(seconds: 3)}) async {
    await observer.dispose();
    await _syncCenter.dispose();
    await eventBus.dispose();
    await drainOrchestrator.executeClose(
        drainTimeout: drainTimeout, periodicTimer: _periodicTimer);
    _periodicTimer = null;
  }
}
