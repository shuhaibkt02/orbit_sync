import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'package:http/http.dart' as http;
import '../../connectivity/connectivity_monitor.dart';
import '../../storage/sync_storage.dart';
import '../../transport/domain/interfaces/sync_http_adapter.dart';
import '../../transport/domain/models/transport_request.dart';
import '../domain/models/orbit_record.dart';
import '../domain/models/orbit_sync_status.dart';
import '../domain/models/refresh_result.dart';
import '../domain/models/rest_endpoints.dart';
import '../domain/policies/debounce_stream_transformer.dart';
import '../domain/policies/sqlite_type_sanitizer.dart';
import '../domain/policies/endpoint_url_resolver.dart';
import '../domain/models/media_config.dart';
import '../../consensus/domain/models/priority.dart';
import 'entity_hydrator.dart';

/// Strongly-typed entity table handle providing compile-time safe CRUD,
/// automated SQLite sanitization, and reactive stream subscriptions (Challenge 4).
class OrbitTable<T> {
  final String name;
  final String primaryKey;
  final String baseUrl;
  final T Function(Map<String, dynamic> json) fromJson;
  final Map<String, dynamic> Function(T item) toJson;
  SyncStorage storage;
  final RestEndpoints<T>? endpoints;
  final RestEndpoint? restEndpoint;
  final Future<String?> Function()? getAuthToken;
  final SqliteTypeSanitizer sanitizer;
  EntityHydrator hydrator;
  final TableEndpointResolver<T> endpointResolver;
  final Duration? cacheTtl;
  final http.Client? httpClient;
  final SyncHttpAdapter? adapter;
  final ConnectivityMonitor? connectivity;
  final Priority defaultPriority;
  final Duration? defaultSla;
  final Duration? defaultCoolingTime;
  final MediaConfig? media;
  final int? maxCacheRecords;

  DateTime? _lastHydratedAt;
  Future<RefreshResult>? _inFlightHydration;

  DateTime? get lastHydratedAt => _lastHydratedAt;

  OrbitTable({
    required this.name,
    required this.fromJson,
    required this.toJson,
    required this.storage,
    this.primaryKey = 'id',
    this.baseUrl = '',
    this.endpoints,
    this.restEndpoint,
    this.getAuthToken,
    this.sanitizer = const SqliteTypeSanitizer(),
    this.cacheTtl,
    this.httpClient,
    this.adapter,
    this.connectivity,
    this.defaultPriority = Priority.background,
    this.defaultSla,
    this.defaultCoolingTime,
    this.media,
    this.maxCacheRecords,
  })  : hydrator = EntityHydrator(storage: storage, sanitizer: sanitizer),
        endpointResolver = TableEndpointResolver<T>(
          entityName: name,
          baseUrl: baseUrl,
          endpoints: endpoints,
          restEndpoint: restEndpoint,
        );

  /// Ensures the local entity table exists before executing reads.
  Future<void> _ensureTable() async {
    await storage.registerEntityTable(name, {});
  }

  /// Updates the storage and hydrator handles to a newly switched user session.
  void updateStorage(SyncStorage newStorage) {
    storage = newStorage;
    hydrator = EntityHydrator(storage: newStorage, sanitizer: sanitizer);
  }

  /// Pins a record locally, setting `expires_at = NULL` making it immune to TTL cache eviction.
  Future<void> pin(String id) async {
    await storage.db
        .execute('UPDATE "$name" SET expires_at = NULL WHERE id = ?', [id]);
  }

  /// Unpins a record, optionally setting a new TTL expiration.
  Future<void> unpin(String id, {Duration? ttl}) async {
    final expiresAt = ttl != null
        ? DateTime.now().millisecondsSinceEpoch + ttl.inMilliseconds
        : null;
    await storage.db.execute(
        'UPDATE "$name" SET expires_at = ? WHERE id = ?', [expiresAt, id]);
  }

  Future<String> save(
    T item, {
    String? id,
    Map<String, String>? pathParams,
    Map<String, dynamic>? queryParams,
    Map<String, String>? headers,
    Duration? sla,
    Duration? holdFor,
    Duration? coolingTime,
    Duration? ttl,
    dynamic priority,
    String? correlationTag,
    String? authorId,
    String? userId,
    String? dependsOnMutationId,
  }) async {
    final rawMap = toJson(item);
    final targetId = id ??
        (rawMap[primaryKey] ?? rawMap['id'] ?? rawMap['_id'])?.toString() ??
        UuidV7.generate();

    final isUpdate = (endpoints != null || restEndpoint != null) &&
        (await storage.db.getAll(
                'SELECT id FROM "$name" WHERE id = ? LIMIT 1', [targetId]))
            .isNotEmpty;
    final ep = endpointResolver.resolveSave(
      item: item,
      id: targetId,
      isUpdate: isUpdate,
      pathParams: pathParams,
      queryParams: queryParams,
    );

    final resolvedHeaders = await endpointResolver.resolveHeaders(headers);
    final effectiveAuthorId = authorId ??
        (rawMap['author_id'] as String?) ??
        (rawMap['authorId'] as String?);
    final effectiveUserId = userId ??
        (rawMap['user_id'] as String?) ??
        (rawMap['userId'] as String?);

    String? effectiveMediaPath =
        (rawMap['media_path'] as String?) ?? (rawMap['mediaPath'] as String?);
    if (effectiveMediaPath == null && media != null) {
      final field = media!.fieldName;
      if (rawMap.containsKey(field)) {
        final val = rawMap[field];
        if (val is OrbitAttachment) {
          effectiveMediaPath = val.localPath;
        } else if (val is Map) {
          effectiveMediaPath =
              (val['local_path'] ?? val['localPath'])?.toString();
        } else if (val is String) {
          effectiveMediaPath = val;
        }
      }
    }
    if (effectiveMediaPath == null) {
      for (final val in rawMap.values) {
        if (val is Map &&
            (val['type'] == 'orbit_attachment' || val['local_path'] != null)) {
          effectiveMediaPath =
              (val['local_path'] ?? val['localPath'])?.toString();
          break;
        }
      }
    }

    final int resolvedPriority;
    if (priority is Priority) {
      resolvedPriority = priority.value;
    } else if (priority is int) {
      resolvedPriority = priority;
    } else {
      resolvedPriority = defaultPriority.value;
    }

    final effectiveSla = sla ?? defaultSla;
    final effectiveCooling = coolingTime ?? defaultCoolingTime;

    await storage.save(
      entity: name,
      id: targetId,
      data: rawMap,
      endpointUrl: ep.url,
      httpMethod: ep.method,
      sla: effectiveSla,
      holdFor: holdFor,
      coolingTime: effectiveCooling,
      ttl: ttl,
      priority: resolvedPriority,
      correlationTag: correlationTag,
      headers: resolvedHeaders,
      authorId: effectiveAuthorId,
      userId: effectiveUserId,
      mediaPath: effectiveMediaPath,
      dependsOnMutationId: dependsOnMutationId,
    );

    if (maxCacheRecords != null && maxCacheRecords! > 0) {
      unawaited(storage.pruneToQuota(name, maxCacheRecords: maxCacheRecords!));
    }

    return targetId;
  }

  Future<String?> delete(
    String id, {
    Map<String, String>? pathParams,
    Map<String, dynamic>? queryParams,
    Map<String, String>? headers,
    Duration? undoWindow,
    Duration? coolingTime,
    Duration? holdFor,
    String? authorId,
    String? userId,
  }) async {
    final ep = endpointResolver.resolveDelete(
        id: id, pathParams: pathParams, queryParams: queryParams);
    final resolvedHeaders = await endpointResolver.resolveHeaders(headers);
    final effectiveCooling = coolingTime ?? defaultCoolingTime;
    return await storage.delete(
      entity: name,
      id: id,
      endpointUrl: ep.url,
      httpMethod: ep.method,
      undoWindow: undoWindow,
      coolingTime: effectiveCooling,
      holdFor: holdFor,
      headers: resolvedHeaders,
      authorId: authorId,
      userId: userId,
    );
  }

  Future<bool> undoDelete(String id) async =>
      await storage.undoDelete(entity: name, id: id);

  Future<T?> get(String id) async {
    await _ensureTable();
    final rows = await storage.db.getAll(
      'SELECT data_json, updated_at, expires_at FROM "$name" WHERE id = ? LIMIT 1',
      [id],
    );
    if (rows.isEmpty) return null;
    return fromJson(sanitizer.decodeRow(Map<String, dynamic>.from(rows.first)));
  }

  Future<OrbitRecord<T>?> getRecord(String id) async {
    final records =
        await queryRecords(where: 'id = ?', whereArgs: [id], limit: 1);
    return records.isEmpty ? null : records.first;
  }

  static final _systemCols = {
    'id',
    'version',
    'updated_at',
    'expires_at',
    '_base_snapshot_json',
    'data_json'
  };

  String _rewriteWhere(String whereClause) {
    if (whereClause.contains('json_extract')) return whereClause;
    return whereClause.replaceAllMapped(
      RegExp(
          r'\b([a-zA-Z_][a-zA-Z0-9_]*)\b(?=\s*(=|!=|<>|>|<|>=|<=|LIKE|IS|IN))',
          caseSensitive: false),
      (match) {
        final col = match.group(1)!;
        if (_systemCols.contains(col.toLowerCase())) return col;
        return "json_extract(data_json, '\$.$col')";
      },
    );
  }

  String _rewriteOrderBy(String orderByClause) {
    if (orderByClause.contains('json_extract')) return orderByClause;
    return orderByClause.replaceAllMapped(
      RegExp(r'\b([a-zA-Z_][a-zA-Z0-9_]*)\b(?=\s*(ASC|DESC|\,|$))',
          caseSensitive: false),
      (match) {
        final col = match.group(1)!;
        if (col.toUpperCase() == 'ASC' || col.toUpperCase() == 'DESC') {
          return col;
        }
        if (_systemCols.contains(col.toLowerCase())) return col;
        return "json_extract(data_json, '\$.$col')";
      },
    );
  }

  String _buildSql(String? where, String? orderBy, int? limit, [int? offset]) {
    var sql = 'SELECT data_json, updated_at, expires_at FROM "$name"';
    if (where != null && where.isNotEmpty) {
      sql += ' WHERE ${_rewriteWhere(where)}';
    }
    if (orderBy != null && orderBy.isNotEmpty) {
      sql += ' ORDER BY ${_rewriteOrderBy(orderBy)}';
    } else {
      sql += ' ORDER BY updated_at DESC';
    }
    if (limit != null) {
      sql += ' LIMIT $limit';
      if (offset != null) {
        sql += ' OFFSET $offset';
      }
    } else if (offset != null) {
      sql += ' LIMIT -1 OFFSET $offset';
    }
    return sql;
  }

  Future<void> _checkHydrateOnRead() async {
    if (endpoints?.list == null || baseUrl.isEmpty) return;

    final now = DateTime.now();
    final isExpired = cacheTtl != null &&
        _lastHydratedAt != null &&
        now.difference(_lastHydratedAt!) > cacheTtl!;

    if (_lastHydratedAt == null || isExpired) {
      if (_inFlightHydration != null) {
        await _inFlightHydration;
        return;
      }

      if (_lastHydratedAt == null && cacheTtl == null) {
        await _ensureTable();
        final rows = await storage.db.getAll('SELECT id FROM "$name" LIMIT 1');
        if (rows.isNotEmpty) {
          _lastHydratedAt = now;
          return;
        }
      }

      final future = refresh();
      _inFlightHydration = future;
      try {
        await future;
      } finally {
        _inFlightHydration = null;
      }
    }
  }

  Future<List<T>> query({
    bool Function(T item)? filter,
    dynamic where,
    List<dynamic> whereArgs = const [],
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    await _ensureTable();
    await _checkHydrateOnRead();

    bool Function(T item)? predicate = filter;
    String? sqlWhere;
    if (where is bool Function(T)) {
      predicate = where;
    } else if (where is String) {
      sqlWhere = where;
    }

    if (predicate != null) {
      final sql = _buildSql(sqlWhere, orderBy, null, null);
      final rows =
          await storage.db.getAll(sql, sanitizer.sanitizeList(whereArgs));
      Iterable<T> stream = rows
          .map((r) =>
              fromJson(sanitizer.decodeRow(Map<String, dynamic>.from(r))))
          .where(predicate);
      if (offset != null && offset > 0) {
        stream = stream.skip(offset);
      }
      if (limit != null && limit > 0) {
        stream = stream.take(limit);
      }
      return stream.toList();
    }

    final sql = _buildSql(sqlWhere, orderBy, limit, offset);
    final rows =
        await storage.db.getAll(sql, sanitizer.sanitizeList(whereArgs));
    return rows
        .map((r) => fromJson(sanitizer.decodeRow(Map<String, dynamic>.from(r))))
        .toList();
  }

  Stream<List<T>> watch({
    bool Function(T item)? filter,
    dynamic where,
    List<dynamic> whereArgs = const [],
    String? orderBy,
    int? limit,
    int? offset,
  }) {
    unawaited(_checkHydrateOnRead());

    bool Function(T item)? predicate = filter;
    String? sqlWhere;
    if (where is bool Function(T)) {
      predicate = where;
    } else if (where is String) {
      sqlWhere = where;
    }

    if (predicate != null) {
      final sql = _buildSql(sqlWhere, orderBy, null, null);
      final stream = watchRaw(sql, whereArgs);
      return stream.map((list) {
        Iterable<T> s = list.where(predicate!);
        if (offset != null && offset > 0) s = s.skip(offset);
        if (limit != null && limit > 0) s = s.take(limit);
        return s.toList();
      });
    }

    final sql = _buildSql(sqlWhere, orderBy, limit, offset);
    return watchRaw(sql, whereArgs);
  }

  Stream<List<T>> watchRaw(String query,
      [List<dynamic> parameters = const []]) {
    return Stream<List<T>>.multi((multiController) {
      final sub = storage
          .watch(query, parameters: sanitizer.sanitizeList(parameters))
          .leadingImmediateDebounce(const Duration(milliseconds: 100))
          .map((rs) => rs
              .map((r) =>
                  fromJson(sanitizer.decodeRow(Map<String, dynamic>.from(r))))
              .toList())
          .listen(
            multiController.addSync,
            onError: multiController.addErrorSync,
            onDone: multiController.closeSync,
          );
      multiController.onCancel = () => sub.cancel();
      multiController.onPause = sub.pause;
      multiController.onResume = sub.resume;
    });
  }

  String _buildRecordsSql(String? where, String? orderBy, int? limit,
      [int? offset]) {
    var sql = '''
      SELECT * FROM (
        SELECT t.id, t.version, t.updated_at, t.expires_at,
               CASE WHEN o.status = 'validation_error' THEN o.payload_json ELSE t.data_json END as data_json,
               o.base_snapshot_json as _base_snapshot_json, o.status as _outbox_status, o.error_details_json as _outbox_err, o.mutation_id as _outbox_mut_id, o.op as _outbox_op
        FROM "$name" t
        LEFT JOIN _sync_outbox o ON o.sequence_id = (
          SELECT MAX(o2.sequence_id)
          FROM _sync_outbox o2
          WHERE o2.entity_name = '$name' AND o2.entity_id = CAST(t.id AS TEXT)
            AND o2.status IN ('pending', 'in_flight', 'failed', 'dlq', 'validation_error')
        )
        UNION ALL
        SELECT o.entity_id as id, 1 as version, o.updated_at, null as expires_at,
               CASE WHEN o.status = 'validation_error' THEN o.payload_json ELSE o.base_snapshot_json END as data_json,
               o.base_snapshot_json as _base_snapshot_json,
               o.status as _outbox_status, o.error_details_json as _outbox_err, o.mutation_id as _outbox_mut_id, o.op as _outbox_op
        FROM _sync_outbox o
        WHERE o.entity_name = '$name'
          AND (
            (o.op = 'delete' AND o.status = 'pending' AND o.dispatch_after > (strftime('%s', 'now') * 1000))
            OR o.status = 'validation_error'
          )
          AND o.entity_id NOT IN (SELECT id FROM "$name")
      ) AS _records
    ''';
    if (where != null && where.isNotEmpty) {
      sql += ' WHERE ${_rewriteWhere(where)}';
    }
    if (orderBy != null && orderBy.isNotEmpty) {
      sql += ' ORDER BY ${_rewriteOrderBy(orderBy)}';
    } else {
      sql += ' ORDER BY updated_at DESC';
    }
    if (limit != null) {
      sql += ' LIMIT $limit';
      if (offset != null) {
        sql += ' OFFSET $offset';
      }
    } else if (offset != null) {
      sql += ' LIMIT -1 OFFSET $offset';
    }
    return sql;
  }

  Future<List<OrbitRecord<T>>> queryRecords({
    bool Function(OrbitRecord<T> record)? filter,
    dynamic where,
    List<dynamic> whereArgs = const [],
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    await _ensureTable();
    await _checkHydrateOnRead();

    bool Function(OrbitRecord<T> record)? predicate = filter;
    String? sqlWhere;
    if (where is bool Function(OrbitRecord<T>)) {
      predicate = where;
    } else if (where is String) {
      sqlWhere = where;
    }

    if (predicate != null) {
      final sql = _buildRecordsSql(sqlWhere, orderBy, null, null);
      final rows =
          await storage.db.getAll(sql, sanitizer.sanitizeList(whereArgs));
      Iterable<OrbitRecord<T>> stream =
          rows.map(_mapRowToRecord).where(predicate);
      if (offset != null && offset > 0) {
        stream = stream.skip(offset);
      }
      if (limit != null && limit > 0) {
        stream = stream.take(limit);
      }
      return stream.toList();
    }

    final sql = _buildRecordsSql(sqlWhere, orderBy, limit, offset);
    final rows =
        await storage.db.getAll(sql, sanitizer.sanitizeList(whereArgs));
    return rows.map(_mapRowToRecord).toList();
  }

  Stream<List<OrbitRecord<T>>> watchRecords({
    bool Function(OrbitRecord<T> record)? filter,
    dynamic where,
    List<dynamic> whereArgs = const [],
    String? orderBy,
    int? limit,
    int? offset,
  }) {
    unawaited(_checkHydrateOnRead());

    bool Function(OrbitRecord<T> record)? predicate = filter;
    String? sqlWhere;
    if (where is bool Function(OrbitRecord<T>)) {
      predicate = where;
    } else if (where is String) {
      sqlWhere = where;
    }

    if (predicate != null) {
      final sql = _buildRecordsSql(sqlWhere, orderBy, null, null);
      final stream = Stream<List<OrbitRecord<T>>>.multi((multiController) {
        final sub = storage
            .watch(sql, parameters: sanitizer.sanitizeList(whereArgs))
            .leadingImmediateDebounce(const Duration(milliseconds: 100))
            .map((rs) => rs.map(_mapRowToRecord).toList())
            .listen(
              multiController.addSync,
              onError: multiController.addErrorSync,
              onDone: multiController.closeSync,
            );
        multiController.onCancel = () => sub.cancel();
        multiController.onPause = sub.pause;
        multiController.onResume = sub.resume;
      });
      return stream.map((list) {
        Iterable<OrbitRecord<T>> s = list.where(predicate!);
        if (offset != null && offset > 0) s = s.skip(offset);
        if (limit != null && limit > 0) s = s.take(limit);
        return s.toList();
      });
    }

    final sql = _buildRecordsSql(sqlWhere, orderBy, limit, offset);
    return Stream<List<OrbitRecord<T>>>.multi((multiController) {
      final sub = storage
          .watch(sql, parameters: sanitizer.sanitizeList(whereArgs))
          .leadingImmediateDebounce(const Duration(milliseconds: 100))
          .map((rs) => rs.map(_mapRowToRecord).toList())
          .listen(
            multiController.addSync,
            onError: multiController.addErrorSync,
            onDone: multiController.closeSync,
          );
      multiController.onCancel = () => sub.cancel();
      multiController.onPause = sub.pause;
      multiController.onResume = sub.resume;
    });
  }

  Stream<T?> watchById(String id) {
    return watch(where: 'id = ?', whereArgs: [id], limit: 1)
        .map((list) => list.isEmpty ? null : list.first);
  }

  OrbitRecord<T> _mapRowToRecord(Map<dynamic, dynamic> r) {
    final rowMap = Map<String, dynamic>.from(r);
    final outboxStatus = rowMap.remove('_outbox_status') as String?;
    final outboxOp = rowMap.remove('_outbox_op') as String?;
    final outboxErr = rowMap.remove('_outbox_err') as String?;
    final mutId = rowMap.remove('_outbox_mut_id') as String?;
    final baseJson = rowMap.remove('_base_snapshot_json') as String?;
    final expiresAt = rowMap['expires_at'] as int?;
    final updatedAtMs = rowMap['updated_at'] as int?;
    final updatedAt = updatedAtMs != null
        ? DateTime.fromMillisecondsSinceEpoch(updatedAtMs)
        : null;

    T? previousData;
    if (baseJson != null && baseJson.isNotEmpty && baseJson != '{}') {
      try {
        final decoded = jsonDecode(baseJson);
        if (decoded is Map) {
          previousData =
              fromJson(sanitizer.decodeRow(Map<String, dynamic>.from(decoded)));
        }
      } catch (_) {}
    }

    final status = switch (outboxStatus) {
      'pending' => outboxOp == 'delete'
          ? OrbitSyncStatus.pendingDelete
          : OrbitSyncStatus.pending,
      'in_flight' => OrbitSyncStatus.inFlight,
      'failed' || 'dlq' => OrbitSyncStatus.failed,
      'validation_error' => OrbitSyncStatus.rejected,
      _ => OrbitSyncStatus.synced,
    };

    return OrbitRecord<T>(
      data: fromJson(sanitizer.decodeRow(rowMap)),
      previousData: previousData,
      status: status,
      errorMessage: outboxErr,
      mutationId: mutId,
      expiresAt: expiresAt,
      updatedAt: updatedAt,
    );
  }

  Future<RefreshResult> fetch({
    Map<String, dynamic>? queryParams,
    Map<String, String>? pathParams,
    Map<String, String>? headers,
  }) =>
      refresh(
          queryParams: queryParams, pathParams: pathParams, headers: headers);

  Future<RefreshResult> refresh({
    Map<String, dynamic>? queryParams,
    Map<String, String>? pathParams,
    Map<String, String>? headers,
  }) async {
    if (connectivity != null && !connectivity!.isOnline) {
      return RefreshResult.offline;
    }
    if (endpoints?.list == null && restEndpoint == null) {
      return const RefreshResult(status: RefreshStatus.success, count: 0);
    }
    final String resolved;
    if (restEndpoint != null) {
      resolved = endpointResolver.urlResolver.resolveListUrl(
        restEndpoint!,
        pathParams: pathParams,
        queryParams: queryParams,
      );
    } else {
      final req = endpoints!.list!(queryParams);
      resolved = endpointResolver.urlResolver.resolve(
        req.path,
        pathParams: pathParams,
        queryParams: queryParams ?? req.queryParams,
      );
    }
    final uri = Uri.parse(resolved);

    try {
      final reqHeaders = <String, String>{'content-type': 'application/json'};
      if (getAuthToken != null) {
        final token = await getAuthToken!();
        if (token != null) {
          reqHeaders['authorization'] =
              token.startsWith('Bearer ') ? token : 'Bearer $token';
        }
      }
      final resolvedHeaders = await endpointResolver.resolveHeaders(headers);
      if (resolvedHeaders != null) reqHeaders.addAll(resolvedHeaders);

      final String body;
      final int statusCode;

      if (adapter != null) {
        final resp = await adapter!.send(TransportRequest(
          uri: uri,
          method: 'GET',
          headers: reqHeaders,
        ));
        statusCode = resp.statusCode;
        body = resp.body;
      } else {
        final client = httpClient ?? http.Client();
        try {
          final resp = await client.get(uri, headers: reqHeaders);
          statusCode = resp.statusCode;
          body = resp.body;
        } finally {
          if (httpClient == null) {
            client.close();
          }
        }
      }

      if (statusCode < 200 || statusCode >= 300) {
        return RefreshResult(
            status: RefreshStatus.error, errorMessage: 'HTTP $statusCode');
      }

      final decoded = jsonDecode(body);
      final unwrap = endpoints?.unwrapList ?? RestEndpoints.defaultUnwrap;
      final items = unwrap(decoded);

      final count = await hydrator.hydrateBatch(
        entity: name,
        items: items,
        primaryKey: primaryKey,
        maxCacheRecords: maxCacheRecords,
      );
      _lastHydratedAt = DateTime.now();
      return RefreshResult(status: RefreshStatus.success, count: count);
    } on SocketException catch (_) {
      return RefreshResult.offline;
    } on http.ClientException catch (_) {
      return RefreshResult.offline;
    } on TimeoutException catch (_) {
      return RefreshResult.offline;
    } catch (e) {
      final errStr = e.toString().toLowerCase();
      if (errStr.contains('socket') ||
          errStr.contains('offline') ||
          errStr.contains('connection') ||
          errStr.contains('network') ||
          errStr.contains('failed host lookup')) {
        return RefreshResult.offline;
      }
      return RefreshResult(
          status: RefreshStatus.error, errorMessage: e.toString());
    }
  }
}
