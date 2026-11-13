import 'package:sqlite3/sqlite3.dart' show ResultSet;

/// Inverted contract for outbox mutations, domain table records, and cache maintenance.
abstract class IOutboxRepository {
  /// Atomically commits domain entity record and outbox mutation envelope.
  Future<String> save({
    required String entity,
    required String id,
    required Map<String, dynamic> data,
    int version = 1,
    String? dependsOnMutationId,
    int schemaVersion = 1,
    String? endpointUrl,
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

  /// Atomically marks domain entity deleted and appends delete envelope to outbox.
  Future<String?> delete({
    required String entity,
    required String id,
    String? endpointUrl,
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

  /// Rolls back an optimistic mutation using its stored base snapshot.
  Future<void> rollbackOptimistic(String mutationId, {String status = 'conflict'});

  /// Prunes completed synced outbox records older than [retention].
  Future<int> pruneSyncedOutbox({Duration retention = const Duration(days: 7)});

  /// Prunes completed synced outbox records older than [olderThan].
  Future<int> pruneSynced({Duration olderThan = const Duration(days: 7)});

  /// Prunes expired local domain cache records where expires_at < now.
  Future<int> pruneExpiredCache(String entity);

  /// Prunes oldest records (LRU) when cached entity count exceeds [maxCacheRecords].
  Future<int> pruneToQuota(String entity, {required int maxCacheRecords});

  /// Registers an entity table with universal 5-column schema and system indices.
  Future<void> registerEntityTable(
    String entityName,
    Map<String, String> columnTypes, {
    String? foreignKeyClause,
  });

  /// Executes an asynchronous query against the storage engine.
  Future<ResultSet> query(String query, [List<dynamic> parameters = const []]);

  /// Streams reactive updates on any query.
  Stream<ResultSet> watch(String query, {List<dynamic> parameters = const []});

  /// Triggers a WAL checkpoint or file truncation.
  Future<void> checkpoint({bool truncate = false});

  /// Closes underlying engine connections.
  Future<void> close();
}
