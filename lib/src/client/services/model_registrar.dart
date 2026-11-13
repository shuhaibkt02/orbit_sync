import 'dart:async';
import 'package:http/http.dart' as http;
import '../../connectivity/connectivity_monitor.dart';
import '../../storage/sync_storage.dart';
import '../../transport/domain/interfaces/sync_http_adapter.dart';
import '../../consensus/domain/models/priority.dart';
import '../domain/models/media_config.dart';
import '../domain/models/rest_endpoints.dart';
import 'orbit_table_impl.dart';

/// Manages registration and lifecycle of strongly-typed [OrbitTable] instances.
class ModelRegistrar {
  SyncStorage storage;
  final String baseUrl;
  final Future<String?> Function()? getAuthToken;
  final http.Client? httpClient;
  final SyncHttpAdapter? adapter;
  final ConnectivityMonitor? connectivity;
  final Map<String, OrbitTable> tables = {};
  final Map<String, _ModelSchemaInfo> _schemas = {};

  ModelRegistrar({
    required this.storage,
    this.baseUrl = '',
    this.getAuthToken,
    this.httpClient,
    this.adapter,
    this.connectivity,
  });

  OrbitTable<T> register<T>({
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
    String? Function(dynamic json)? idExtractor,
    Map<String, String>? headers,
    FutureOr<Map<String, String>> Function()? dynamicHeaders,
    Map<String, String> Function()? queryParams,
  }) {
    RestEndpoint? effectiveRestEndpoint = restEndpoint;
    if (endpoint is RestEndpoint) {
      effectiveRestEndpoint = endpoint;
    }

    final hasAnyEndpointConfig = endpoint != null ||
        path != null ||
        createEndpoint != null ||
        createPath != null ||
        updateEndpoint != null ||
        updatePath != null ||
        deleteEndpoint != null ||
        deletePath != null ||
        listEndpoint != null ||
        listPath != null ||
        effectiveRestEndpoint != null;

    final effectiveEndpoint = effectiveRestEndpoint != null
        ? effectiveRestEndpoint.path
        : (endpoint is String
            ? endpoint
            : (path ??
                (hasAnyEndpointConfig
                    ? (endpoint?.toString() ?? path)
                    : '/$name')));

    if (effectiveRestEndpoint == null &&
        (queryParams != null || dynamicHeaders != null)) {
      effectiveRestEndpoint = RestEndpoint(
        path: effectiveEndpoint ?? '/$name',
        createPath: createPath ?? createEndpoint,
        queryParams: queryParams,
        headers: dynamicHeaders ?? (headers != null ? () => headers : null),
      );
    }

    final effectiveFromJson = fromJson;
    final effectiveToJson = toJson;

    final effectiveEndpoints = endpoints ??
        (effectiveRestEndpoint != null
            ? RestEndpoints.fromRestEndpoint(
                effectiveRestEndpoint,
                toJson: effectiveToJson,
                primaryKey: primaryKey,
                unwrapList: unwrapList,
                idExtractor: idExtractor,
              )
            : RestEndpoints.fromConfig(
                endpoint: effectiveEndpoint,
                createMethod: createMethod,
                createEndpoint: createEndpoint,
                createPath: createPath,
                updateMethod: updateMethod,
                updateEndpoint: updateEndpoint,
                updatePath: updatePath,
                deleteMethod: deleteMethod,
                deleteEndpoint: deleteEndpoint,
                deletePath: deletePath,
                listEndpoint: listEndpoint,
                listPath: listPath,
                listMethod: listMethod,
                unwrapList: unwrapList,
                primaryKey: primaryKey,
                toJson: effectiveToJson,
                headers: headers,
                idExtractor: idExtractor,
              ));

    final table = OrbitTable<T>(
      name: name,
      primaryKey: primaryKey,
      baseUrl: baseUrl,
      fromJson: effectiveFromJson,
      toJson: effectiveToJson,
      storage: storage,
      endpoints: effectiveEndpoints,
      restEndpoint: effectiveRestEndpoint,
      getAuthToken: getAuthToken,
      cacheTtl: cacheTtl,
      httpClient: httpClient,
      adapter: adapter,
      connectivity: connectivity,
      defaultPriority: priority ?? Priority.background,
      defaultSla: sla,
      defaultCoolingTime: coolingTime,
      media: media,
      maxCacheRecords: maxCacheRecords,
    );
    tables[name] = table;
    _schemas[name] = _ModelSchemaInfo(
      columns: columns,
      indexes: indexes,
      foreignKeyClause: foreignKeys.isNotEmpty ? foreignKeys.first : null,
    );
    storage.registerEntityTable(name, columns,
        foreignKeyClause: foreignKeys.isNotEmpty ? foreignKeys.first : null);
    for (final idx in indexes) {
      SqliteSchema.createExpressionIndex(storage.db, name, idx);
    }
    return table;
  }

  /// Re-binds registered table instances to a new database storage and reapplies schema.
  Future<void> updateStorage(SyncStorage newStorage) async {
    storage = newStorage;
    for (final entry in tables.entries) {
      entry.value.updateStorage(newStorage);
      final schema = _schemas[entry.key];
      if (schema != null) {
        await newStorage.registerEntityTable(
          entry.key,
          schema.columns,
          foreignKeyClause: schema.foreignKeyClause,
        );
        for (final idx in schema.indexes) {
          SqliteSchema.createExpressionIndex(newStorage.db, entry.key, idx);
        }
      }
    }
  }

  /// Retrieves a previously registered strongly-typed table handle by [name].
  OrbitTable<T> table<T>(String name) {
    final t = tables[name];
    if (t == null) {
      throw StateError(
        'Table "$name" has not been registered yet. Call orbit.collection<T>(name: "$name", ...) first.',
      );
    }
    return t as OrbitTable<T>;
  }
}

class _ModelSchemaInfo {
  final Map<String, String> columns;
  final List<String> indexes;
  final String? foreignKeyClause;

  const _ModelSchemaInfo({
    required this.columns,
    required this.indexes,
    this.foreignKeyClause,
  });
}
