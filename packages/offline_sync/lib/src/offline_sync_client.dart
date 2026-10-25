import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart' show ResultSet, Row;
import 'consensus/sync_worker.dart';
import 'sync_profile.dart';
import 'transport/sync_transport.dart';
import 'consensus/domain/models/sync_failure.dart';
import 'consensus/domain/models/sync_status_summary.dart';
import 'client/orbit_client.dart';
import 'client/orbit_client_impl.dart';
import 'observability/domain/models/sync_event.dart';

/// Top-level developer facade for the offline-first synchronization engine.
class OfflineSyncClient extends OrbitClientImpl {
  OfflineSyncClient._({
    required super.storage,
    required super.worker,
    required super.profile,
    required super.connectivity,
    super.getAuthToken,
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
    Future<void> Function()? onScheduleNativeAlarm,
  }) async {
    final impl = await OrbitClient.initialize(
      databasePath: databasePath,
      serverUrl: serverUrl,
      transport: transport,
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
    );

    return OfflineSyncClient._(
      storage: impl.storage,
      worker: impl.worker,
      profile: impl.profile,
      connectivity: impl.connectivity,
      getAuthToken: getAuthToken,
    );
  }

  /// Backward-compatible overload allowing `client.registerTable('tasks', {'title': 'TEXT'})`.
  @override
  Future<void> registerTable(
    String entityName,
    Map<String, String> columnTypes, {
    String? foreignKeyClause,
    String? url,
  }) async {
    await registerEntity(
      entityName,
      url: url,
      columnTypes: columnTypes,
      foreignKeyClause: foreignKeyClause,
    );
  }

  Future<int> pruneExpiredCache(String entity) async {
    final count = await storage.pruneExpiredCache(entity);
    if (count > 0) observer.publish(DatabasePrunedEvent(timestamp: DateTime.now().toUtc(), prunedCount: count));
    return count;
  }
  Future<SyncStatusSummary> getSummary() => queryHelper.getSummary();
  Stream<SyncStatusSummary> watchSummary() => queryHelper.watchSummary();
  Future<List<SyncFailure>> getFailures() => queryHelper.getFailures();
  Stream<List<SyncFailure>> watchFailures() => queryHelper.watchFailures();
  Future<List<OutboxRecord>> getRecords({String? status, int limit = 100}) => queryHelper.getRecords(status: status, limit: limit);
  Stream<List<OutboxRecord>> watchRecords({String? status, int limit = 100}) => queryHelper.watchRecords(status: status, limit: limit);
  Future<List<OutboxRecord>> getStaleRecords({required Duration maxAge}) => queryHelper.getStaleRecords(maxAge: maxAge);
  Stream<List<OutboxRecord>> watchStaleRecords({required Duration maxAge}) => queryHelper.watchStaleRecords(maxAge: maxAge);

  Stream<ResultSet> watchFailedMutations() => watch("SELECT * FROM _sync_outbox WHERE status IN ('failed', 'dlq', 'validation_error') ORDER BY created_at DESC");
  Future<List<Row>> getFailedMutations() => query("SELECT * FROM _sync_outbox WHERE status IN ('failed', 'dlq', 'validation_error') ORDER BY created_at DESC");

  Future<void> retryMutation(String mutationId, {bool syncNow = false}) async {
    await queryHelper.retryMutation(mutationId);
    if (syncNow) await sync(force: true);
  }

  Future<void> retryAllFailed({bool syncNow = false}) async {
    await queryHelper.retryAllFailed();
    if (syncNow) await sync(force: true);
  }

  Future<void> cancelMutation(String mutationId) => queryHelper.cancelMutation(mutationId);
  Future<void> markSynced(String mutationId) => queryHelper.markSynced(mutationId);

  /// Headless sync runner for OS background schedulers.
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
}

/// Friendly alias for [OfflineSyncClient].
typedef OrbitClientLegacy = OfflineSyncClient;
