import 'dart:async';
import 'package:sqlite3/sqlite3.dart' show Row, ResultSet;
import '../storage/sync_storage.dart';
import '../consensus/sync_worker.dart';
import '../sync_profile.dart';
import '../connectivity/connectivity_monitor.dart';
import 'domain/interfaces/i_orbit_client.dart';
import 'domain/interfaces/i_orbit_table.dart';
import 'domain/models/orbit_sync_event.dart';
import 'domain/models/sync_job.dart';
import 'domain/models/rest_endpoints.dart';
import 'domain/models/client_exceptions.dart';
import 'services/sync_event_bus.dart';
import 'services/sync_coordinator.dart';
import 'services/entity_hydrator.dart';
import 'services/drain_orchestrator.dart';
import 'services/session_manager.dart';
import 'services/orbit_table_impl.dart';
import 'services/dashboard_query_helper.dart';

/// Concrete implementation of the unified application facade (Layer 5).
class OrbitClientImpl implements IOrbitClient {
  final SyncStorage storage;
  final SyncWorker worker;
  final SyncProfile profile;
  final ConnectivityMonitor connectivity;
  final Future<String?> Function()? getAuthToken;

  final SyncEventBus eventBus = SyncEventBus();
  final SessionManager sessionManager = const SessionManager();
  late final EntityHydrator hydrator;
  late final SyncCoordinator coordinator;
  late final DrainOrchestrator drainOrchestrator;
  late final DashboardQueryHelper queryHelper;

  final Map<String, IOrbitTable> _tables = {};
  final Map<String, String> _entityUrls = {};
  final List<StreamController<dynamic>> _activeWatchControllers = [];

  Timer? _periodicTimer;
  Duration _periodicInterval = const Duration(seconds: 30);
  bool _isPaused = false;

  OrbitClientImpl({
    required this.storage,
    required this.worker,
    required this.profile,
    required this.connectivity,
    this.getAuthToken,
  }) {
    hydrator = EntityHydrator(storage: storage);
    coordinator = SyncCoordinator(worker: worker, eventBus: eventBus);
    drainOrchestrator = DrainOrchestrator(
      storage: storage,
      worker: worker,
      connectivity: connectivity,
      activeWatchControllers: _activeWatchControllers,
      awaitInFlightSync: () async => coordinator.currentInFlightSync,
    );
    queryHelper = DashboardQueryHelper(storage: storage, watchFn: watch);
  }

  @override
  Stream<OrbitSyncEvent> get syncEvents => eventBus.stream;
  bool get isPaused => _isPaused;
  bool get isClosed => drainOrchestrator.isClosed;

  @override
  IOrbitTable<T> registerModel<T>({
    required String name,
    required T Function(Map<String, dynamic> json) fromJson,
    required Map<String, dynamic> Function(T item) toJson,
    String primaryKey = 'id',
    List<String> indexes = const [],
    List<String> foreignKeys = const [],
    RestEndpoints<T>? endpoints,
  }) {
    final table = OrbitTableImpl<T>(
      name: name,
      primaryKey: primaryKey,
      fromJson: fromJson,
      toJson: toJson,
      storage: storage,
      endpoints: endpoints,
      getAuthToken: getAuthToken,
    );
    _tables[name] = table;
    storage.registerEntityTable(name, const {}, foreignKeyClause: foreignKeys.isNotEmpty ? foreignKeys.first : null);
    return table;
  }

  IOrbitTable<T> registerTypedTable<T>({
    required String name,
    required T Function(Map<String, dynamic> json) fromJson,
    required Map<String, dynamic> Function(T item) toJson,
    String primaryKey = 'id',
    List<String> indexes = const [],
    List<String> foreignKeys = const [],
    RestEndpoints<T>? endpoints,
  }) => registerModel<T>(name: name, fromJson: fromJson, toJson: toJson, primaryKey: primaryKey, indexes: indexes, foreignKeys: foreignKeys, endpoints: endpoints);

  @override
  Future<void> registerTable(String entityName, Map<String, String> columnTypes, {String? foreignKeyClause, String? url}) async {
    if (url != null && url.isNotEmpty) _entityUrls[entityName] = url;
    await storage.registerEntityTable(entityName, columnTypes, foreignKeyClause: foreignKeyClause);
  }

  Future<void> registerEntity(String entityName, {String? url, Map<String, String> columnTypes = const {}, String? foreignKeyClause}) async {
    if (url != null && url.isNotEmpty) _entityUrls[entityName] = url;
    await storage.registerEntityTable(entityName, columnTypes, foreignKeyClause: foreignKeyClause);
  }

  Future<String> save({required String entity, String? id, required Map<String, dynamic> data, int version = 1, String? dependsOnMutationId, int schemaVersion = 1, String? url, String? httpMethod, Duration? holdFor, Duration? sla, Duration? ttl, int priority = 0, String? correlationTag}) async {
    if (isClosed) throw const ClientClosedException('save');
    final effectiveId = id ?? (data['id'] as String?) ?? UuidV7.generate();
    return await storage.save(entity: entity, id: effectiveId, data: data, version: version, dependsOnMutationId: dependsOnMutationId, schemaVersion: schemaVersion, endpointUrl: url ?? _entityUrls[entity], httpMethod: httpMethod, holdFor: holdFor, sla: sla, ttl: ttl, priority: priority, correlationTag: correlationTag);
  }

  Future<String> store(String entity, Map<String, dynamic> data, {String? id, String? url, String? httpMethod, Duration? holdFor, Duration? sla, Duration? ttl, int priority = 0, String? correlationTag}) async {
    final effectiveId = id ?? (data['id'] as String?) ?? UuidV7.generate();
    await save(entity: entity, id: effectiveId, data: data, url: url, httpMethod: httpMethod, holdFor: holdFor, sla: sla, ttl: ttl, priority: priority, correlationTag: correlationTag);
    return effectiveId;
  }

  Future<String?> delete({required String entity, required String id, String? url, String? httpMethod, Duration? undoWindow}) async {
    if (isClosed) throw const ClientClosedException('delete');
    return await storage.delete(entity: entity, id: id, endpointUrl: url ?? _entityUrls[entity], httpMethod: httpMethod, undoWindow: undoWindow);
  }

  Future<bool> undoDelete({required String entity, required String id}) => storage.undoDelete(entity: entity, id: id);
  Future<List<Row>> restore(String entity, {String? where, List<dynamic> whereArgs = const [], String? orderBy}) =>
      query('SELECT * FROM $entity${where != null ? ' WHERE $where' : ''}${orderBy != null ? ' ORDER BY $orderBy' : ''}', whereArgs);
  Future<Row?> restoreById(String entity, String id) async {
    final rows = await query('SELECT * FROM $entity WHERE id = ? LIMIT 1', [id]);
    return rows.isEmpty ? null : rows.first;
  }

  @override
  Future<List<Row>> query(String query, [List<dynamic> parameters = const []]) {
    if (isClosed) throw const ClientClosedException('query');
    return storage.db.getAll(query, parameters);
  }

  @override
  Stream<ResultSet> watch(String query, {List<dynamic> parameters = const []}) {
    if (isClosed) throw const ClientClosedException('watch');
    return storage.watch(query, parameters: parameters);
  }

  @override
  SyncJob sync({String? entity, bool force = false}) => coordinator.triggerSync(force: force, isPaused: _isPaused, isClosed: isClosed);
  Future<int> fetchAndStore(String entity, {required String url, Map<String, String>? headers}) => hydrator.fetchAndStore(entity, url: url, headers: headers, getAuthToken: getAuthToken);

  void startPeriodicSync({Duration? interval}) {
    _periodicInterval = interval ?? (profile == SyncProfile.basic ? const Duration(seconds: 60) : profile == SyncProfile.standard ? const Duration(seconds: 30) : const Duration(seconds: 15));
    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(_periodicInterval, (_) { if (!_isPaused) sync(); });
  }

  void pauseSync() { _isPaused = true; }
  void resumeSync() { _isPaused = false; sync(); }
  Future<void> notifyAppResumed() async {
    await connectivity.notifyAppResumed();
    if (connectivity.isOnline && !_isPaused) await sync();
  }
  StreamSubscription<bool> attachConnectivity(Stream<bool> isOnlineStream) => isOnlineStream.listen((isOnline) { if (isOnline && !_isPaused) sync(); });

  @override
  Future<void> close({Duration drainTimeout = const Duration(seconds: 3)}) async {
    await drainOrchestrator.executeClose(drainTimeout: drainTimeout, periodicTimer: _periodicTimer);
    _periodicTimer = null;
    await eventBus.dispose();
  }
}
