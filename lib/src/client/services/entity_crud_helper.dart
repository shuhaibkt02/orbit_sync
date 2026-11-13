import '../../storage/sync_storage.dart';
import '../../observability/sync_observer.dart';
import '../../observability/domain/models/sync_event.dart';
import '../domain/models/client_exceptions.dart';
import '../domain/policies/sqlite_type_sanitizer.dart';

/// Handles untyped raw entity CRUD operations and outbox queueing.
class EntityCrudHelper {
  final SyncStorage storage;
  final SyncObserver observer;
  final Map<String, String> entityUrls = {};
  final bool Function() isClosed;

  EntityCrudHelper({
    required this.storage,
    required this.observer,
    required this.isClosed,
  });

  Future<void> registerTable(String entityName, Map<String, String> columnTypes, {String? foreignKeyClause, String? url}) async {
    if (url != null && url.isNotEmpty) entityUrls[entityName] = url;
    await storage.registerEntityTable(entityName, columnTypes, foreignKeyClause: foreignKeyClause);
  }

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
  }) async {
    if (isClosed()) throw const ClientClosedException('save');
    final effectiveId = id ?? (data['id'] as String?) ?? (data['_id'] as String?) ?? UuidV7.generate();
    final existing = await storage.db.getAll("SELECT mutation_id FROM _sync_outbox WHERE entity_name = ? AND entity_id = ? AND status = 'pending' LIMIT 1", [entity, effectiveId]);
    final mutId = await storage.save(
      entity: entity, id: effectiveId, data: data, version: version, dependsOnMutationId: dependsOnMutationId,
      schemaVersion: schemaVersion, endpointUrl: url ?? entityUrls[entity], httpMethod: httpMethod,
      holdFor: holdFor, coolingTime: coolingTime,
      sla: sla, ttl: ttl, priority: priority, correlationTag: correlationTag, headers: headers,
      authorId: authorId, userId: userId, mediaPath: mediaPath,
    );
    observer.publish(existing.isNotEmpty
        ? MutationCoalescedEvent(timestamp: DateTime.now().toUtc(), mutationId: mutId, entity: entity, entityId: effectiveId)
        : MutationQueuedEvent(timestamp: DateTime.now().toUtc(), mutationId: mutId, entity: entity, entityId: effectiveId));
    return mutId;
  }

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
  }) async {
    final effectiveId = id ?? (data['id'] as String?) ?? (data['_id'] as String?) ?? UuidV7.generate();
    final effectiveData = id != null ? ({...data, 'id': id}) : data;
    await save(
      entity: entity,
      id: effectiveId,
      data: effectiveData,
      url: url ?? entityUrls[entity],
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
    return effectiveId;
  }

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
  }) async {
    if (isClosed()) throw const ClientClosedException('delete');
    return await storage.delete(
      entity: entity,
      id: id,
      endpointUrl: url ?? entityUrls[entity],
      httpMethod: httpMethod,
      undoWindow: undoWindow,
      coolingTime: coolingTime,
      holdFor: holdFor,
      headers: headers,
      authorId: authorId,
      userId: userId,
    );
  }

  Future<bool> undoDelete({String? entity, required String id}) => storage.undoDelete(entity: entity, id: id);

  Future<List<Map<String, dynamic>>> restore(String entity, {String? where, List<dynamic> whereArgs = const [], String? orderBy}) async {
    SyncValidator.validateEntity(entity);
    final rows = await storage.db.getAll(
      'SELECT * FROM "$entity"${where != null ? ' WHERE $where' : ''}${orderBy != null ? ' ORDER BY $orderBy' : ''}',
      const SqliteTypeSanitizer().sanitizeList(whereArgs),
    );
    return rows.map((r) => const SqliteTypeSanitizer().decodeRow(Map<String, dynamic>.from(r))).toList();
  }

  Future<Map<String, dynamic>?> restoreById(String entity, String id) async {
    SyncValidator.validateEntity(entity);
    SyncValidator.validateId(id);
    final rows = await storage.db.getAll('SELECT * FROM "$entity" WHERE id = ? LIMIT 1', [id]);
    return rows.isEmpty ? null : const SqliteTypeSanitizer().decodeRow(Map<String, dynamic>.from(rows.first));
  }
}
