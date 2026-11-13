import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import '../../storage/sync_storage.dart';
import '../../consensus/sync_worker.dart';
import '../../sync_profile.dart';
import '../../transport/sync_transport.dart';
import '../../connectivity/connectivity_monitor.dart';
import '../orbit_client_impl.dart';
import 'schema_migration_runner.dart';
import '../../observability/domain/models/sync_event.dart'
    show SlaWarningEvent, SlaBreachedEvent;

/// Bootstraps and initializes storage, migration runners, workers, and network monitors.
class OrbitClientInitializer {
  const OrbitClientInitializer._();

  /// Resolves the physical database path for a user session or guest fallback.
  static String resolveDatabasePath({
    String? databasePath,
    String? appDir,
    String? baseDir,
    String? userId,
  }) {
    if (databasePath != null && databasePath.isNotEmpty) {
      return databasePath;
    }
    final base = appDir ?? baseDir;
    if (base == null || base.isEmpty) {
      return 'orbit.db';
    }
    final cleanBase = base.replaceAll(RegExp(r'[/\\]+$'), '');
    final cleanUser = userId?.trim();
    if (cleanUser != null && cleanUser.isNotEmpty) {
      return '$cleanBase/orbit/users/$cleanUser/orbit.db';
    }
    return '$cleanBase/orbit/guest/orbit.db';
  }

  static Future<OrbitClientImpl> initialize({
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
  }) async {
    final effectivePath = resolveDatabasePath(
      databasePath: databasePath,
      appDir: appDir,
      baseDir: baseDir,
      userId: userId,
    );

    String? effectiveAppDir = appDir ?? baseDir;
    if (effectiveAppDir == null && effectivePath != ':memory:') {
      final match = RegExp(
              r'^(.*)[/\\]orbit[/\\](?:users[/\\][^/\\]+|guest)[/\\]orbit\.db$')
          .firstMatch(effectivePath);
      if (match != null) {
        effectiveAppDir = match.group(1);
      } else {
        effectiveAppDir = File(effectivePath).parent.path;
      }
    }
    if (transport == null) {
      if (httpClient != null) {
        transport = SyncTransport.http(
          baseUrl: baseUrl,
          httpClient: httpClient,
          getAuthToken: getAuthToken,
          pushPath: pushPath ?? 'sync/push',
          pullPath: pullPath ?? 'sync/pull',
        );
      } else {
        transport = SyncTransport.dio(
          dio: dio,
          baseUrl: baseUrl,
          getAuthToken: getAuthToken,
          pushPath: pushPath ?? 'sync/push',
          pullPath: pullPath ?? 'sync/pull',
        );
      }
    }

    if (baseUrl != null && baseUrl.isEmpty) {
      throw ArgumentError('baseUrl must not be empty.');
    }

    String effectiveBase = baseUrl ?? '';
    if (effectiveBase.isEmpty &&
        transport is HttpSyncTransport &&
        transport.baseUrl.isNotEmpty) {
      effectiveBase = transport.baseUrl;
    }

    if (effectiveBase.isNotEmpty) {
      final uri = Uri.tryParse(effectiveBase);
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
        throw ArgumentError(
            'baseUrl must be a valid HTTP/HTTPS URL (e.g. "https://api.example.com"). Got: "$effectiveBase"');
      }
    }

    if (transport is HttpSyncTransport) {
      if (transport.baseUrl.isEmpty && effectiveBase.isNotEmpty) {
        transport.baseUrl = effectiveBase;
      }
      if (pushPath != null) {
        transport.pushPath = pushPath;
      }
      if (pullPath != null) {
        transport.pullPath = pullPath;
      }
    }

    final storage =
        await SyncStorage.open(path: effectivePath, maxReaders: maxReaders);
    final migrationRunner = SchemaMigrationRunner(
      storage: storage,
      targetSchemaVersion: currentSchemaVersion,
      migrator: migrator,
    );
    await migrationRunner.runEagerMigrations();

    final worker = SyncWorker(
      storage: storage,
      baseUrl: effectiveBase,
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
      baseUrl: effectiveBase.isNotEmpty ? effectiveBase : null,
      probeUrl: healthCheckUrl,
      defaultProbeUrl:
          healthCheckUrl ?? (effectiveBase.isNotEmpty ? effectiveBase : null),
      reachabilityChecker: reachabilityChecker,
      onScheduleNativeAlarm: onScheduleNativeAlarm,
    );

    final client = OrbitClientImpl(
      storage: storage,
      worker: worker,
      profile: profile,
      connectivity: connectivity,
      baseUrl: effectiveBase,
      getAuthToken: getAuthToken,
      appDir: effectiveAppDir,
      currentUserId: userId,
      maxReaders: maxReaders,
      currentSchemaVersion: currentSchemaVersion,
      migrator: migrator,
      nowMsProvider: nowMsProvider,
      pullPageLimit: pullPageLimit,
      scopeFilter: scopeFilter,
      onAuthExpired: onAuthExpired,
      validateInvariants: validateInvariants,
      onLog: onLog,
      transport: transport,
      httpClient: httpClient,
      backoffPolicy: backoffPolicy,
    );

    connectivity.onConnectivityChanged.listen((isOnline) {
      if (isOnline && !client.isPaused) client.sync();
    });

    if (onSlaWarning != null) {
      client.observer.onSlaWarning.listen(onSlaWarning);
    }
    if (onSlaBreached != null) {
      client.observer.onSlaBreached.listen(onSlaBreached);
    }

    return client;
  }

  static Future<void> headlessSync({
    String? databasePath,
    String? appDir,
    String? baseDir,
    String? userId,
    String? baseUrl,
    SyncTransport? transport,
    Future<String?> Function()? getAuthToken,
    void Function(String message)? onLog,
  }) async {
    final client = await initialize(
      databasePath: databasePath,
      appDir: appDir,
      baseDir: baseDir,
      userId: userId,
      baseUrl: baseUrl,
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
