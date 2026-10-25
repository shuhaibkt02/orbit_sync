import 'dart:async';
import 'package:http/http.dart' as http;
import '../storage/sync_storage.dart';
import '../sync_profile.dart';
import '../sync_transport.dart';
import '../http_sync_transport.dart';
import 'domain/models/sync_result.dart';
import 'domain/policies/backoff_policy.dart';
import 'domain/interfaces/i_sync_worker.dart';
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
  int currentSchemaVersion;
  MutationMigrator? migrator;

  late final ConflictReconciler _reconciler;
  late final PagePullOrchestrator _pullOrchestrator;
  late final BatchPushOrchestrator _pushOrchestrator;
  late final GenerationSwapManager _swapManager;

  String get serverUrl => transport is HttpSyncTransport ? (transport as HttpSyncTransport).serverUrl : '';
  http.Client? get httpClient => transport is HttpSyncTransport ? (transport as HttpSyncTransport).httpClient : null;

  SyncWorker({
    required this.storage,
    String serverUrl = '',
    SyncTransport? transport,
    this.profile = SyncProfile.enterprise,
    http.Client? client,
    BackoffPolicy? backoffPolicy,
    this.nowMsProvider,
    this.pullPageLimit = 50,
    this.scopeFilter,
    Future<String?> Function()? getAuthToken,
    this.onAuthExpired,
    this.validateInvariants,
    this.currentSchemaVersion = 1,
    this.migrator,
    this.onLog,
  })  : _getAuthToken = getAuthToken,
        backoffPolicy = backoffPolicy ?? BackoffPolicy(),
        transport = transport ??
            HttpSyncTransport(
              serverUrl: serverUrl,
              client: client,
              getAuthToken: getAuthToken,
            ) {
    _initServices();
    this.transport.onRemoteChange?.listen((_) {
      onLog?.call('Orbit: Real-time remote change detected. Triggering sync.');
      sync();
    });
  }

  void _initServices() {
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
    );
    _pushOrchestrator = BatchPushOrchestrator(
      storage: storage,
      transport: transport,
      profile: profile,
      backoffPolicy: backoffPolicy,
      currentSchemaVersion: currentSchemaVersion,
      migrator: migrator,
      onLog: onLog,
      onAuthExpired: _handleAuthExpired,
      nowMsProvider: nowMsProvider,
    );
    _swapManager = GenerationSwapManager(storage: storage, transport: transport);
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
  Future<SyncPushResult> pushBatch({
    int batchSize = 10,
    String? chaos,
    bool force = false,
  }) {
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
    await pushBatch(force: force);
    await pullAll();
  }

  @override
  void dispose() {
    transport.dispose();
  }
}
