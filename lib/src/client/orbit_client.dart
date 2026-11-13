import 'dart:async';
import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart' show Row, ResultSet;
import '../storage/sync_storage.dart';
import '../consensus/sync_worker.dart';
import '../consensus/domain/models/sync_failure.dart';
import '../consensus/domain/models/sync_status_summary.dart';
import '../sync_profile.dart';
import '../connectivity/connectivity_monitor.dart';
import '../consensus/domain/models/priority.dart';
import 'domain/models/media_config.dart';
import '../transport/sync_transport.dart';
import 'domain/models/orbit_sync_event.dart';
import 'domain/models/sync_job.dart';
import 'domain/models/rest_endpoints.dart';
import '../observability/sync_observer.dart';
import '../observability/domain/models/sync_event.dart'
    show SlaWarningEvent, SlaBreachedEvent;
import '../observability/services/sync_center.dart';
import 'services/session_manager.dart';
import 'services/orbit_table_impl.dart';
import 'services/orbit_client_initializer.dart';

/// Top-level developer facade and factory for initializing and sandboxing the Orbit offline sync engine.
abstract class OrbitClient {
  /// Deterministic 16-character SHA-256 session path hash (Challenge 5).
  static String hashUserId(String userId) =>
      const SessionManager().computeSessionPath('', userId).split('/')[2];

  /// Resolves the SQLite database path for a user session or guest fallback.
  static String resolveDatabasePath({
    String? databasePath,
    String? appDir,
    String? baseDir,
    String? userId,
  }) =>
      OrbitClientInitializer.resolveDatabasePath(
        databasePath: databasePath,
        appDir: appDir,
        baseDir: baseDir,
        userId: userId,
      );

  /// Merges unpushed mutations from an anonymous guest session into a target user database.
  static Future<int> mergeGuestSession({
    required String guestDatabasePath,
    required String targetDatabasePath,
  }) =>
      const SessionManager().mergeGuestSession(
        guestDatabasePath: guestDatabasePath,
        targetDatabasePath: targetDatabasePath,
      );

  /// Initializes storage, outbox schema, connection pools, and sync worker.
  static Future<OrbitClient> initialize({
    String? databasePath,
    String? appDir,
    String? baseDir,
    String? userId,
    String? baseUrl,
    SyncTransport? transport,
    Dio? dio,
    SyncProfile profile = SyncProfile.standard,
    http.Client? httpClient,
    BackoffPolicy? backoffPolicy,
    int Function()? nowMsProvider,
    int maxReaders = 4,
    int pullPageLimit = 50,
    Map<String, dynamic>? scopeFilter,
    Future<String?> Function()? getAuthToken,
    Future<void> Function()? onAuthExpired,
    String? Function(String entity, Map<String, dynamic> record)?
        validateInvariants,
    int currentSchemaVersion = 1,
    MutationMigrator? migrator,
    void Function(String message)? onLog,
    String? healthCheckUrl,
    Duration connectivityTimeout = const Duration(seconds: 3),
    Future<bool> Function()? reachabilityChecker,
    Future<void> Function()? onScheduleNativeAlarm,
    String? pushPath,
    String? pullPath,
    void Function(SlaWarningEvent event)? onSlaWarning,
    void Function(SlaBreachedEvent event)? onSlaBreached,
  }) =>
      OrbitClientInitializer.initialize(
        databasePath: databasePath,
        appDir: appDir,
        baseDir: baseDir,
        userId: userId,
        baseUrl: baseUrl,
        transport: transport,
        dio: dio,
        profile: profile,
        httpClient: httpClient,
        backoffPolicy: backoffPolicy,
        nowMsProvider: nowMsProvider,
        maxReaders: maxReaders,
        pullPageLimit: pullPageLimit,
        scopeFilter: scopeFilter,
        getAuthToken: getAuthToken,
        onAuthExpired: onAuthExpired,
        validateInvariants: validateInvariants,
        currentSchemaVersion: currentSchemaVersion,
        migrator: migrator,
        onLog: onLog,
        healthCheckUrl: healthCheckUrl,
        connectivityTimeout: connectivityTimeout,
        reachabilityChecker: reachabilityChecker,
        onScheduleNativeAlarm: onScheduleNativeAlarm,
        pushPath: pushPath,
        pullPath: pullPath,
        onSlaWarning: onSlaWarning,
        onSlaBreached: onSlaBreached,
      );

  /// Headless sync runner for OS background schedulers (WorkManager, AlarmManager, BGAppRefreshTask).
  static Future<void> headlessSync({
    String? databasePath,
    String? appDir,
    String? baseDir,
    String? userId,
    String? baseUrl,
    SyncTransport? transport,
    Future<String?> Function()? getAuthToken,
    void Function(String message)? onLog,
  }) =>
      OrbitClientInitializer.headlessSync(
        databasePath: databasePath,
        appDir: appDir,
        baseDir: baseDir,
        userId: userId,
        baseUrl: baseUrl,
        transport: transport,
        getAuthToken: getAuthToken,
        onLog: onLog,
      );

  /// Active user ID, or null if running in guest mode or direct path mode.
  String? get currentUserId;

  /// Alias for [currentUserId].
  String? get userId => currentUserId;

  /// Switches active user session, cleanly closing the current database connection
  /// and opening the target user's isolated database, preserving existing offline outbox
  /// and cache data of both users.
  Future<void> switchUser(String newUserId);

  /// Root REST base URL configured at initialization.
  String get baseUrl;

  /// Defines and registers a high-level REST collection with explicit HTTP verbs and zero magic guessing.
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
  });

  /// Registers a strongly-typed entity table handle (Challenge 4).
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
  });

  /// Alias for [registerModel] for developers who prefer typed table naming.
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
  });

  /// Registers an untyped table schema with custom columns, foreign keys, and endpoint URL.
  Future<void> registerTable(
    String entityName,
    Map<String, String> columnTypes, {
    String? foreignKeyClause,
    String? url,
  });

  /// Registers an entity table with an optional REST endpoint URL.
  Future<void> registerEntity(
    String entityName, {
    String? url,
    Map<String, String> columnTypes = const {},
    String? foreignKeyClause,
  });

  /// Restores raw records from a domain table.
  Future<List<Map<String, dynamic>>> restore(String entity,
      {String? where, List<dynamic> whereArgs = const [], String? orderBy});

  /// Restores a single raw record from a domain table by ID.
  Future<Map<String, dynamic>?> restoreById(String entity, String id);

  /// Consensus sync worker managing background push and pull lifecycles (Layer 2).
  SyncWorker get worker;

  /// Underlying transport engine (e.g. [HttpSyncTransport] with [DioHttpAdapter]).
  SyncTransport get transport;

  /// Active sync profile tier (basic, standard, enterprise).
  SyncProfile get profile;

  /// Retrieves a previously registered strongly-typed table handle by [name].
  OrbitTable<T> table<T>(String name);

  /// Low-level storage handle for advanced direct SQL execution or maintenance.
  SyncStorage get storage;

  /// Unified diagnostic surface for watching processed outbox items, monitoring summaries, and 1-tap retry actions.
  OrbitSyncCenter get syncCenter;

  /// Triggers an immediate synchronization run across all registered entities.
  Future<void> syncNow();

  /// Retries a single rejected, failed, or quarantined mutation.
  Future<void> retryItem(String mutationId);

  /// Saves a domain record into local SQLite and queues an outbox mutation.
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
  });

  /// Deletes a domain record locally and queues a DELETE mutation in outbox.
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
  });

  /// Restores a deleted record locally if within its undoWindow / cooling window.
  Future<bool> undoDelete({String? entity, required String id});

  /// Prunes completed synced outbox records older than [retention].
  Future<int> pruneSyncedOutbox({Duration retention = const Duration(days: 7)});

  /// Helper for storing an untyped entity and queueing a mutation.
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
  });

  /// Executes bidirectional sync returning an operation-scoped [SyncJob].
  SyncJob sync({String? entity, bool force = false, bool pull = false});

  /// Whether database connections and background workers have been closed.
  bool get isClosed;

  /// Whether automated background sync is currently paused.
  bool get isPaused;

  /// Starts recurring periodic sync at the specified [interval].
  void startPeriodicSync({Duration? interval});

  /// Pauses automated background sync.
  void pauseSync();

  /// Resumes automated background sync and triggers a sync pass.
  void resumeSync();

  /// Attaches an external connectivity stream to trigger sync upon reconnection.
  StreamSubscription<bool> attachConnectivity(Stream<bool> isOnline);

  /// Connectivity monitor managing flap guards and reachability checks (Layer 3).
  ConnectivityMonitor get connectivity;

  /// Direct REST hydration helper to fetch remote records and save them to local storage.
  Future<int> fetchAndStore(String entity,
      {required String url, Map<String, String>? headers});

  /// Telemetry stream of sync events with correlation IDs.
  Stream<OrbitSyncEvent> get syncEvents;

  /// Central observability hub emitting typed telemetry streams and managing in-memory logs (Layer 6).
  SyncObserver get observer;

  /// Restores records from local storage with optional SQL where clause.
  Future<List<Row>> query(String sql, [List<dynamic> parameters = const []]);

  /// Watches query updates reactively with leading-immediate debounce.
  Stream<ResultSet> watch(String query, {List<dynamic> parameters = const []});

  /// Closes database connections and stops timers with a graceful drain budget.
  Future<void> close({Duration drainTimeout = const Duration(seconds: 3)});

  /// Real-time summary of pending, in-flight, synced, and failed mutations.
  Future<SyncStatusSummary> getSummary();

  /// Watches outbox summary updates reactively.
  Stream<SyncStatusSummary> watchSummary();

  /// Retrieves list of all failed and quarantined mutations.
  Future<List<SyncFailure>> getFailures();

  /// Watches failed and quarantined mutations reactively.
  Stream<List<SyncFailure>> watchFailures();

  /// Retrieves raw failed, dlq, and validation_error outbox records.
  Future<List<Row>> getFailedMutations();

  /// Watches raw failed, dlq, and validation_error outbox records reactively.
  Stream<ResultSet> watchFailedMutations();

  /// Manually prunes expired domain cache records for an entity table and emits [DatabasePrunedEvent].
  Future<int> pruneExpiredCache(String entity);

  /// Queries all mutations with optional status filter.
  Future<List<OutboxRecord>> getRecords({String? status, int limit = 100});

  /// Watches mutations reactively with optional status filter.
  Stream<List<OutboxRecord>> watchRecords({String? status, int limit = 100});

  /// Finds mutations that have exceeded their business SLA window.
  Future<List<OutboxRecord>> getStaleRecords({required Duration maxAge});

  /// Watches mutations that exceed their business SLA window.
  Stream<List<OutboxRecord>> watchStaleRecords({required Duration maxAge});

  /// Retries a specific quarantined mutation by ID.
  Future<void> retryMutation(String mutationId, {bool syncNow = false});

  /// Retries all failed and quarantined mutations immediately.
  Future<void> retryAllFailed({bool syncNow = true});

  /// Soft rejects a poisoned mutation, quarantining it without fatal failure.
  Future<void> softRejectRecord(String entity, String id, {String? reason});

  /// Discards a pending or failed mutation.
  Future<void> cancelMutation(String mutationId);

  /// Manually marks a mutation as synced.
  Future<void> markSynced(String mutationId);

  /// When true, forces offline status for manual QA and testing.
  bool get simulateOffline;
  set simulateOffline(bool value);

  /// Synchronously returns whether the client is currently connected to the network.
  bool get isOnline;
}
