import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart' show Row, ResultSet;
import '../storage/sync_storage.dart';
import '../consensus/sync_worker.dart';
import '../sync_profile.dart';
import '../transport/sync_transport.dart';
import '../connectivity/connectivity_monitor.dart';
import 'domain/models/orbit_sync_event.dart';
import 'domain/models/sync_job.dart';
import 'domain/models/rest_endpoints.dart';
import 'services/session_manager.dart';
import 'services/schema_migration_runner.dart';
import 'services/orbit_table_impl.dart';
import 'orbit_client_impl.dart';

/// Top-level developer facade and factory for initializing and sandboxing the Orbit offline sync engine.
abstract class OrbitClient {
  /// Deterministic 16-character SHA-256 session path hash (Challenge 5).
  static String hashUserId(String userId) =>
      const SessionManager().computeSessionPath('', userId).split('/')[2];

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
  static Future<OrbitClientImpl> initialize({
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
    Future<void> Function()? onScheduleNativeAlarm,
  }) async {
    final storage = await SyncStorage.open(path: databasePath, maxReaders: maxReaders);

    // Eagerly migrate pending outbox mutations before worker ticks start (Challenge 7)
    final migrationRunner = SchemaMigrationRunner(
      storage: storage,
      targetSchemaVersion: currentSchemaVersion,
      migrator: migrator,
    );
    await migrationRunner.runEagerMigrations();

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
      onScheduleNativeAlarm: onScheduleNativeAlarm,
    );

    final client = OrbitClientImpl(
      storage: storage,
      worker: worker,
      profile: profile,
      connectivity: connectivity,
      getAuthToken: getAuthToken,
    );

    // Auto-sync upon signal restoration
    connectivity.onConnectivityChanged.listen((isOnline) {
      if (isOnline && !client.isPaused) {
        client.sync();
      }
    });

    return client;
  }

  /// Headless sync runner for OS background schedulers (WorkManager, AlarmManager, BGAppRefreshTask).
  static Future<void> headlessSync({
    required String databasePath,
    String serverUrl = '',
    SyncTransport? transport,
    Future<String?> Function()? getAuthToken,
    void Function(String message)? onLog,
  }) async {
    final client = await initialize(
      databasePath: databasePath,
      serverUrl: serverUrl,
      transport: transport,
      getAuthToken: getAuthToken,
      onLog: onLog,
    );
    try {
      await client.sync();
    } finally {
      await client.close();
    }
  }

  /// Registers a strongly-typed entity table handle (Challenge 4).
  OrbitTable<T> registerModel<T>({
    required String name,
    required T Function(Map<String, dynamic> json) fromJson,
    required Map<String, dynamic> Function(T item) toJson,
    String primaryKey = 'id',
    List<String> indexes = const [],
    List<String> foreignKeys = const [],
    RestEndpoints<T>? endpoints,
  });

  /// Registers an untyped table schema with custom columns, foreign keys, and endpoint URL.
  Future<void> registerTable(
    String entityName,
    Map<String, String> columnTypes, {
    String? foreignKeyClause,
    String? url,
  });

  /// Executes bidirectional sync returning an operation-scoped [SyncJob].
  SyncJob sync({String? entity, bool force = false});

  /// Telemetry stream of sync events with correlation IDs.
  Stream<OrbitSyncEvent> get syncEvents;

  /// Restores records from local storage with optional SQL where clause.
  Future<List<Row>> query(String sql, [List<dynamic> parameters = const []]);

  /// Watches query updates reactively with leading-immediate debounce.
  Stream<ResultSet> watch(String query, {List<dynamic> parameters = const []});

  /// Closes database connections and stops timers with a graceful drain budget.
  Future<void> close({Duration drainTimeout = const Duration(seconds: 3)});
}

/// Backward-compatible alias for [OrbitClient].
typedef IOrbitClient = OrbitClient;
