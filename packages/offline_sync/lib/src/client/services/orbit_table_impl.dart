import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../storage/sync_storage.dart';
import '../domain/interfaces/i_orbit_table.dart';
import '../domain/models/orbit_record.dart';
import '../domain/models/orbit_sync_status.dart';
import '../domain/models/rest_endpoints.dart';
import '../domain/policies/debounce_stream_transformer.dart';
import '../domain/policies/sqlite_type_sanitizer.dart';
import 'entity_hydrator.dart';

/// Implementation of strongly-typed entity table handle (Challenge 4).
class OrbitTableImpl<T> implements IOrbitTable<T> {
  @override
  final String name;
  @override
  final String primaryKey;

  final T Function(Map<String, dynamic> json) fromJson;
  final Map<String, dynamic> Function(T item) toJson;
  final SyncStorage storage;
  final RestEndpoints<T>? endpoints;
  final Future<String?> Function()? getAuthToken;
  final SqliteTypeSanitizer sanitizer;
  final EntityHydrator hydrator;

  OrbitTableImpl({
    required this.name,
    required this.fromJson,
    required this.toJson,
    required this.storage,
    this.primaryKey = 'id',
    this.endpoints,
    this.getAuthToken,
    this.sanitizer = const SqliteTypeSanitizer(),
  }) : hydrator = EntityHydrator(storage: storage, sanitizer: sanitizer);

  @override
  Future<String> save(
    T item, {
    Duration? sla,
    Duration? holdFor,
    Duration? ttl,
    int priority = 0,
    String? correlationTag,
  }) async {
    final rawMap = toJson(item);
    final sanitized = sanitizer.sanitizeMap(rawMap);
    final id = (sanitized[primaryKey] ?? sanitized['id'])?.toString() ?? UuidV7.generate();

    await storage.save(
      entity: name,
      id: id,
      data: sanitized,
      sla: sla,
      holdFor: holdFor,
      ttl: ttl,
      priority: priority,
      correlationTag: correlationTag,
    );
    return id;
  }

  @override
  Future<String?> delete(String id, {Duration? undoWindow}) async {
    return await storage.delete(entity: name, id: id, undoWindow: undoWindow);
  }

  @override
  Future<bool> undoDelete(String id) async {
    return await storage.undoDelete(entity: name, id: id);
  }

  @override
  Future<T?> get(String id) async {
    final rows = await storage.db.getAll('SELECT * FROM $name WHERE $primaryKey = ? LIMIT 1', [id]);
    if (rows.isEmpty) return null;
    return fromJson(Map<String, dynamic>.from(rows.first));
  }

  @override
  Future<List<T>> query({String? where, List<dynamic> whereArgs = const [], String? orderBy, int? limit}) async {
    var sql = 'SELECT * FROM $name';
    if (where != null) sql += ' WHERE $where';
    if (orderBy != null) sql += ' ORDER BY $orderBy';
    if (limit != null) sql += ' LIMIT $limit';
    final rows = await storage.db.getAll(sql, whereArgs);
    return rows.map((r) => fromJson(Map<String, dynamic>.from(r))).toList();
  }

  @override
  Stream<List<T>> watch({String? where, List<dynamic> whereArgs = const [], String? orderBy, int? limit}) {
    var sql = 'SELECT * FROM $name';
    if (where != null) sql += ' WHERE $where';
    if (orderBy != null) sql += ' ORDER BY $orderBy';
    if (limit != null) sql += ' LIMIT $limit';
    return watchRaw(sql, whereArgs);
  }

  @override
  Stream<List<T>> watchRaw(String query, [List<dynamic> parameters = const []]) {
    return storage
        .watch(query, parameters: parameters)
        .leadingImmediateDebounce(const Duration(milliseconds: 100))
        .map((rs) => rs.map((r) => fromJson(Map<String, dynamic>.from(r))).toList());
  }

  @override
  Stream<List<OrbitRecord<T>>> watchRecords() {
    final sql = '''
      SELECT t.*, o.status as _outbox_status, o.error_details_json as _outbox_err, o.mutation_id as _outbox_mut_id
      FROM $name t
      LEFT JOIN _sync_outbox o ON o.entity_name = '$name' AND o.entity_id = t.$primaryKey AND o.status IN ('pending', 'in_flight', 'failed', 'dlq', 'validation_error')
    ''';
    return storage
        .watch(sql)
        .leadingImmediateDebounce(const Duration(milliseconds: 100))
        .map((rs) => rs.map((r) {
              final rowMap = Map<String, dynamic>.from(r);
              final outboxStatus = rowMap.remove('_outbox_status') as String?;
              final outboxErr = rowMap.remove('_outbox_err') as String?;
              final mutId = rowMap.remove('_outbox_mut_id') as String?;

              OrbitSyncStatus status = OrbitSyncStatus.synced;
              if (outboxStatus == 'pending') status = OrbitSyncStatus.pending;
              if (outboxStatus == 'in_flight') status = OrbitSyncStatus.inFlight;
              if (outboxStatus == 'failed' || outboxStatus == 'dlq') status = OrbitSyncStatus.failed;
              if (outboxStatus == 'validation_error') status = OrbitSyncStatus.rejected;

              return OrbitRecord<T>(
                data: fromJson(rowMap),
                status: status,
                errorMessage: outboxErr,
                mutationId: mutId,
              );
            }).toList());
  }

  @override
  Future<int> refresh({Map<String, dynamic>? params}) async {
    if (endpoints?.list == null) return 0;
    final req = endpoints!.list!(params ?? const {});
    final uri = Uri.parse(req.path).replace(queryParameters: req.queryParams?.map((k, v) => MapEntry(k, v.toString())));

    final client = http.Client();
    try {
      final headers = <String, String>{'content-type': 'application/json'};
      if (getAuthToken != null) {
        final token = await getAuthToken!();
        if (token != null) headers['authorization'] = 'Bearer $token';
      }
      if (req.headers != null) headers.addAll(req.headers!);

      final resp = await client.get(uri, headers: headers);
      if (resp.statusCode < 200 || resp.statusCode >= 300) return 0;

      final decoded = jsonDecode(resp.body);
      final unwrap = endpoints?.unwrapList ?? RestEndpoints.defaultUnwrap;
      final items = unwrap(decoded);

      return await hydrator.hydrateBatch(entity: name, items: items, primaryKey: primaryKey);
    } finally {
      client.close();
    }
  }
}
