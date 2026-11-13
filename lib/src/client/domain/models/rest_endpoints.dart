import 'dart:async';

/// HTTP methods supported by the Orbit REST sync engine.
enum HttpMethod {
  get('GET'),
  post('POST'),
  put('PUT'),
  patch('PATCH'),
  delete('DELETE');

  final String verb;
  const HttpMethod(this.verb);

  static HttpMethod fromString(String method) {
    switch (method.toUpperCase()) {
      case 'POST': return HttpMethod.post;
      case 'PUT': return HttpMethod.put;
      case 'PATCH': return HttpMethod.patch;
      case 'DELETE': return HttpMethod.delete;
      case 'GET': default: return HttpMethod.get;
    }
  }
}

/// HTTP request description for entity REST integration.
class RestRequest {
  final String path;
  final HttpMethod method;
  final Map<String, String>? headers;
  final Map<String, dynamic>? queryParams;

  const RestRequest({
    required this.path,
    this.method = HttpMethod.get,
    this.headers,
    this.queryParams,
  });

  String get verb => method.verb;
}

/// Declarative REST routing configuration for an entity collection (Blueprint Layer 6).
///
/// Abolishes hardcoded internal sync paths by allowing host developers to declare
/// base paths, custom overrides, dynamic query parameters, and dynamic request headers.
class RestEndpoint {
  /// Base REST path for the collection (e.g. '/orders' or '/api/v1/orders').
  final String path;

  /// Optional override for POST create operations. Defaults to [path] if omitted.
  final String? createPath;

  /// Optional override for PUT update operations given entity [id].
  /// Defaults to '$path/$id' if omitted.
  final String Function(String id)? updatePath;

  /// Optional override for DELETE operations given entity [id].
  /// Defaults to '$path/$id' if omitted.
  final String Function(String id)? deletePath;

  /// Optional override for GET single item detail operations given entity [id].
  /// Defaults to '$path/$id' if omitted.
  final String Function(String id)? detailPath;

  /// Dynamic query parameter generator evaluated at request execution time.
  final Map<String, String> Function()? queryParams;

  /// Dynamic HTTP headers generator evaluated at request execution time.
  final FutureOr<Map<String, String>> Function()? headers;

  const RestEndpoint({
    required this.path,
    this.createPath,
    this.updatePath,
    this.deletePath,
    this.detailPath,
    this.queryParams,
    this.headers,
  });

  /// Resolves the URL path for POST resource creation.
  String resolveCreatePath() => createPath ?? path;

  /// Resolves the URL path for PUT resource update given [id].
  String resolveUpdatePath(String id) {
    if (updatePath != null) return updatePath!(id);
    return _joinPath(path, id);
  }

  /// Resolves the URL path for DELETE resource deletion given [id].
  String resolveDeletePath(String id) {
    if (deletePath != null) return deletePath!(id);
    return _joinPath(path, id);
  }

  /// Resolves the URL path for GET single resource detail given [id].
  String resolveDetailPath(String id) {
    if (detailPath != null) return detailPath!(id);
    return _joinPath(path, id);
  }

  /// Resolves the URL path for GET collection list.
  String resolveListPath() => path;

  /// Evaluates query parameters dynamically at execution time, merging any [overrides].
  Map<String, String> resolveQueryParams([Map<String, dynamic>? overrides]) {
    final result = <String, String>{};
    if (queryParams != null) {
      result.addAll(queryParams!());
    }
    if (overrides != null) {
      for (final entry in overrides.entries) {
        if (entry.value != null) {
          result[entry.key] = entry.value.toString();
        }
      }
    }
    return result;
  }

  /// Evaluates collection headers dynamically at execution time, merging any [overrides].
  Future<Map<String, String>> resolveHeaders([Map<String, String>? overrides]) async {
    final result = <String, String>{};
    if (headers != null) {
      final dynamicHeaders = await headers!();
      result.addAll(dynamicHeaders);
    }
    if (overrides != null) {
      result.addAll(overrides);
    }
    return result;
  }

  /// Evaluates collection headers synchronously when the callback returns synchronously.
  Map<String, String> resolveHeadersSync([Map<String, String>? overrides]) {
    final result = <String, String>{};
    if (headers != null) {
      final dynamicHeaders = headers!();
      if (dynamicHeaders is Map<String, String>) {
        result.addAll(dynamicHeaders);
      }
    }
    if (overrides != null) {
      result.addAll(overrides);
    }
    return result;
  }

  /// Helper to join base path and id with a single slash.
  static String _joinPath(String base, String id) {
    final cleanBase = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final cleanId = id.startsWith('/') ? id.substring(1) : id;
    return '$cleanBase/$cleanId';
  }
}

/// Declarative REST mapping configuration for typed entity synchronization.
class RestEndpoints<T> {
  final RestRequest Function(Map<String, dynamic>? params)? list;
  final List<Map<String, dynamic>> Function(dynamic json)? unwrapList;
  final RestRequest Function(String id)? getById;
  final RestRequest Function(T item)? create;
  final RestRequest Function(T item)? update;
  final RestRequest Function(String id)? delete;
  final Map<String, String>? headers;
  final String? Function(dynamic response)? idExtractor;

  const RestEndpoints({
    this.list,
    this.unwrapList,
    this.getById,
    this.create,
    this.update,
    this.delete,
    this.headers,
    this.idExtractor,
  });

  /// Constructs declarative REST endpoints from standard collection paths and explicit HTTP methods.
  factory RestEndpoints.fromConfig({
    String? endpoint,
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
    required Map<String, dynamic> Function(T item) toJson,
    Map<String, String>? headers,
    String? Function(dynamic response)? idExtractor,
  }) {
    final base = endpoint ?? path;
    final cEp = createEndpoint ?? createPath ?? base;
    final uEp = updateEndpoint ?? updatePath ?? (base != null ? '$base/:id' : null);
    final dEp = deleteEndpoint ?? deletePath ?? (base != null ? '$base/:id' : null);
    final lEp = listEndpoint ?? listPath ?? base;

    return RestEndpoints<T>(
      list: lEp != null ? (p) => RestRequest(path: lEp, method: listMethod, queryParams: p) : null,
      unwrapList: unwrapList,
      create: cEp != null ? (item) => RestRequest(path: cEp, method: createMethod) : null,
      update: uEp != null
          ? (item) {
              final id = (toJson(item)[primaryKey] ?? toJson(item)['id'])?.toString() ?? '';
              return RestRequest(path: uEp.replaceAll(':id', id), method: updateMethod);
            }
          : null,
      delete: dEp != null
          ? (id) => RestRequest(path: dEp.replaceAll(':id', id), method: deleteMethod)
          : null,
      headers: headers,
      idExtractor: idExtractor,
    );
  }

  /// Constructs [RestEndpoints] adapter from a declarative [RestEndpoint].
  factory RestEndpoints.fromRestEndpoint(
    RestEndpoint endpoint, {
    required Map<String, dynamic> Function(T item) toJson,
    String primaryKey = 'id',
    List<Map<String, dynamic>> Function(dynamic json)? unwrapList,
    String? Function(dynamic response)? idExtractor,
  }) {
    return RestEndpoints<T>(
      list: (params) {
        final q = endpoint.resolveQueryParams(params);
        return RestRequest(path: endpoint.resolveListPath(), method: HttpMethod.get, queryParams: q);
      },
      unwrapList: unwrapList,
      getById: (id) {
        final q = endpoint.resolveQueryParams();
        return RestRequest(path: endpoint.resolveDetailPath(id), method: HttpMethod.get, queryParams: q);
      },
      create: (item) {
        final q = endpoint.resolveQueryParams();
        return RestRequest(path: endpoint.resolveCreatePath(), method: HttpMethod.post, queryParams: q);
      },
      update: (item) {
        final raw = toJson(item);
        final id = (raw[primaryKey] ?? raw['id'] ?? raw['_id'])?.toString() ?? '';
        final q = endpoint.resolveQueryParams();
        return RestRequest(path: endpoint.resolveUpdatePath(id), method: HttpMethod.put, queryParams: q);
      },
      delete: (id) {
        final q = endpoint.resolveQueryParams();
        return RestRequest(path: endpoint.resolveDeletePath(id), method: HttpMethod.delete, queryParams: q);
      },
      headers: null,
      idExtractor: idExtractor,
    );
  }

  /// Default list unwrapper handling raw JSON array or `{"data": [...]}` envelope.
  static List<Map<String, dynamic>> defaultUnwrap(dynamic json) {
    if (json is List) return json.cast<Map<String, dynamic>>();
    if (json is Map && json['data'] is List) return (json['data'] as List).cast<Map<String, dynamic>>();
    return const [];
  }
}
