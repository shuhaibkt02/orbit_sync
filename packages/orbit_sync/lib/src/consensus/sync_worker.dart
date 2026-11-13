import 'dart:async';
import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import '../storage/sync_storage.dart';
import '../sync_profile.dart';
import '../transport/sync_transport.dart';
import 'domain/models/sync_result.dart';
import 'domain/policies/backoff_policy.dart';
import 'domain/interfaces/i_sync_worker.dart';
import 'domain/interfaces/i_conflict_resolver.dart';
import 'services/conflict_reconciler.dart';
import 'services/page_pull_orchestrator.dart';
import 'services/batch_push_orchestrator.dart';
import 'services/generation_swap_manager.dart';

export 'domain/models/sync_result.dart';
export 'domain/policies/backoff_policy.dart';
export 'domain/interfaces/i_sync_worker.dart';
export 'domain/interfaces/i_conflict_resolver.dart';

/// Bidirectional sync worker coordinating push queue, 3-way merge, invariant validation,
/// and generation-swap resync across isolated domain and service layers.
class SyncWorker implements ISyncWorker {
  final SyncStorage storage;
  final SyncTransport transport;
  final SyncProfile profile;
  final int pullPageLimit;
  final Map<String, dynamic>? scopeFilter;
  final BackoffPolicy backoffPolicy;
  final void Function(String message)? onLog;
  final int Function()? nowMsProvider;

  Future<String?> Function()? _getAuthToken;
  Future<String?> Function()? get getAuthToken => _getAuthToken;
  set getAuthToken(Future<String?> Function()? fn) {
    _getAuthToken = fn;
    if (transport is HttpSyncTransport) {
      (transport as HttpSyncTransport).getAuthToken = fn;
    }
  }

  Future<void> Function()? onAuthExpired;
  Future<void>? _refreshFuture;

  String? Function(String entity, Map<String, dynamic> mergedRecord)? validateInvariants;
  int get currentSchemaVersion => _pushOrchestrator.currentSchemaVersion;
  set currentSchemaVersion(int v) => _pushOrchestrator.currentSchemaVersion = v;
  MutationMigrator? get migrator => _pushOrchestrator.migrator;
  set migrator(MutationMigrator? m) => _pushOrchestrator.migrator = m;

  final int maxConcurrentLanes;

  late final ConflictReconciler _reconciler;
  late final PagePullOrchestrator _pullOrchestrator;
  late final BatchPushOrchestrator _pushOrchestrator;
  late final GenerationSwapManager _swapManager;
  StreamSubscription<void>? _remoteChangeSub;

  String get baseUrl => transport is HttpSyncTransport ? (transport as HttpSyncTransport).baseUrl : '';
  http.Client? get httpClient => transport is HttpSyncTransport ? (transport as HttpSyncTransport).httpClient : null;

  SyncWorker({
    required this.storage,
    String? baseUrl,
    SyncTransport? transport,
    this.profile = SyncProfile.enterprise,
    http.Client? client,
    Dio? dio,
    BackoffPolicy? backoffPolicy,
    this.nowMsProvider,
    this.pullPageLimit = 50,
    this.scopeFilter,
    Future<String?> Function()? getAuthToken,
    this.onAuthExpired,
    this.validateInvariants,
    int currentSchemaVersion = 1,
    MutationMigrator? migrator,
    this.onLog,
    this.maxConcurrentLanes = 4,
  })  : _getAuthToken = getAuthToken,
        backoffPolicy = backoffPolicy ?? BackoffPolicy(),
        transport = transport ??
            (client != null
                ? HttpSyncTransport(
                    baseUrl: baseUrl ?? '',
                    client: client,
                    getAuthToken: getAuthToken,
                  )
                : SyncTransport.dio(
                    dio: dio,
                    baseUrl: baseUrl ?? '',
                    getAuthToken: getAuthToken,
                  )) {
    _initServices(currentSchemaVersion, migrator);
    _remoteChangeSub = this.transport.onRemoteChange?.listen((_) {
      onLog?.call('Orbit: Real-time remote change detected. Triggering sync.');
      sync();
    });
  }

  void _initServices(int initialSchemaVersion, MutationMigrator? initialMigrator) {
    _swapManager = GenerationSwapManager(storage: storage, transport: transport);
    _reconciler = ConflictReconciler(
      validateInvariants: (entity, merged) => validateInvariants?.call(entity, merged),
    );
    _pullOrchestrator = PagePullOrchestrator(
      storage: storage,
      transport: transport,
      profile: profile,
      reconciler: _reconciler,
      pullPageLimit: pullPageLimit,
      scopeFilter: scopeFilter,
      onAuthExpired: _handleAuthExpired,
      onExpiredCursor: () async {
        onLog?.call('Orbit: HTTP 410 Gone (expired cursor). Triggering resyncGeneration.');
        await _swapManager.resyncGeneration();
      },
    );
    _pushOrchestrator = BatchPushOrchestrator(
      storage: storage,
      transport: transport,
      profile: profile,
      backoffPolicy: backoffPolicy,
      currentSchemaVersion: initialSchemaVersion,
      migrator: initialMigrator,
      onLog: onLog,
      onAuthExpired: _handleAuthExpired,
      nowMsProvider: nowMsProvider,
      maxConcurrentLanes: maxConcurrentLanes,
    );
  }

  Future<void> _handleAuthExpired() async {
    if (onAuthExpired == null) return;
    if (_refreshFuture != null) {
      await _refreshFuture;
      return;
    }
    _refreshFuture = onAuthExpired!();
    try {
      await _refreshFuture;
    } finally {
      _refreshFuture = null;
    }
  }

  @override
  Future<int> getLastSyncedCursor() => _pullOrchestrator.getLastSyncedCursor();

  @override
  Future<void> setLastSyncedCursor(int cursor) => _pullOrchestrator.setLastSyncedCursor(cursor);

  @override
  void registerConflictResolver(String entity, EntityConflictResolver resolver) {
    _reconciler.registerResolver(entity, resolver);
  }

  void registerIdExtractor(String entity, String? Function(dynamic json) extractor) {
    _pushOrchestrator.registerIdExtractor(entity, extractor);
  }

  @override
  Future<int> reclaimZombies() => _pushOrchestrator.reclaimZombies();

  bool _isSyncing = false;

  @override
  Future<SyncPushResult> pushBatch({
    int batchSize = 10,
    String? chaos,
    bool force = false,
  }) async {
    return _pushOrchestrator.pushBatch(batchSize: batchSize, chaos: chaos, force: force);
  }

  @override
  Future<SyncPullResult> pullPage({String? chaos}) => _pullOrchestrator.pullPage(chaos: chaos);

  @override
  Future<int> pullAll() => _pullOrchestrator.pullAll();

  @override
  Future<bool> resyncGeneration(List<String> entities) => _swapManager.resyncGeneration(entities);

  @override
  Future<void> sync({bool force = false}) async {
    if (_isSyncing) return;
    _isSyncing = true;
    try {
      await pushBatch(force: force);
      await pullAll();
    } finally {
      _isSyncing = false;
    }
  }

  @override
  void dispose() {
    _remoteChangeSub?.cancel();
    transport.dispose();
  }
}
