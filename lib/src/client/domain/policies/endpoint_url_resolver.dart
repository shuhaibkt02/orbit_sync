import 'dart:async';
import '../models/rest_endpoints.dart';

/// Resolves full HTTP endpoint URLs by combining root base URLs with relative entity paths.
class EndpointUrlResolver {
  final String baseUrl;

  const EndpointUrlResolver({this.baseUrl = ''});

  /// Resolves [path] into a complete URL, interpolating path and query parameters safely.
  String resolve(
    String path, {
    String id = '',
    Map<String, String>? pathParams,
    Map<String, dynamic>? queryParams,
  }) {
    var resolvedPath = path.replaceAll(':id', id);
    if (pathParams != null) {
      for (final entry in pathParams.entries) {
        resolvedPath = resolvedPath.replaceAll(':${entry.key}', entry.value);
      }
    }

    String fullUrl;
    if (resolvedPath.startsWith('http://') ||
        resolvedPath.startsWith('https://')) {
      fullUrl = resolvedPath;
    } else if (baseUrl.isEmpty) {
      fullUrl = resolvedPath;
    } else {
      final cleanBase = baseUrl.endsWith('/')
          ? baseUrl.substring(0, baseUrl.length - 1)
          : baseUrl;
      final cleanPath =
          resolvedPath.startsWith('/') ? resolvedPath : '/$resolvedPath';
      fullUrl = '$cleanBase$cleanPath';
    }

    if (queryParams != null && queryParams.isNotEmpty) {
      final nonNull = queryParams.entries.where((e) => e.value != null);
      if (nonNull.isNotEmpty) {
        final uri = Uri.parse(fullUrl);
        final params = Map<String, dynamic>.from(uri.queryParameters);
        for (final e in nonNull) {
          params[e.key] = e.value.toString();
        }
        return uri.replace(queryParameters: params).toString();
      }
    }
    return fullUrl;
  }

  /// Resolves the complete URL for creating a resource (POST) from [endpoint].
  String resolveCreateUrl(
    RestEndpoint endpoint, {
    Map<String, String>? pathParams,
    Map<String, dynamic>? queryParams,
  }) {
    final path = endpoint.resolveCreatePath();
    final effectiveQuery = endpoint.resolveQueryParams(queryParams);
    return resolve(path, pathParams: pathParams, queryParams: effectiveQuery);
  }

  /// Resolves the complete URL for updating a resource (PUT) from [endpoint].
  String resolveUpdateUrl(
    RestEndpoint endpoint,
    String id, {
    Map<String, String>? pathParams,
    Map<String, dynamic>? queryParams,
  }) {
    final path = endpoint.resolveUpdatePath(id);
    final effectiveQuery = endpoint.resolveQueryParams(queryParams);
    return resolve(path,
        id: id, pathParams: pathParams, queryParams: effectiveQuery);
  }

  /// Resolves the complete URL for deleting a resource (DELETE) from [endpoint].
  String resolveDeleteUrl(
    RestEndpoint endpoint,
    String id, {
    Map<String, String>? pathParams,
    Map<String, dynamic>? queryParams,
  }) {
    final path = endpoint.resolveDeletePath(id);
    final effectiveQuery = endpoint.resolveQueryParams(queryParams);
    return resolve(path,
        id: id, pathParams: pathParams, queryParams: effectiveQuery);
  }

  /// Resolves the complete URL for fetching a single resource detail (GET) from [endpoint].
  String resolveDetailUrl(
    RestEndpoint endpoint,
    String id, {
    Map<String, String>? pathParams,
    Map<String, dynamic>? queryParams,
  }) {
    final path = endpoint.resolveDetailPath(id);
    final effectiveQuery = endpoint.resolveQueryParams(queryParams);
    return resolve(path,
        id: id, pathParams: pathParams, queryParams: effectiveQuery);
  }

  /// Resolves the complete URL for listing/fetching collection resources (GET) from [endpoint].
  String resolveListUrl(
    RestEndpoint endpoint, {
    Map<String, String>? pathParams,
    Map<String, dynamic>? queryParams,
  }) {
    final path = endpoint.resolveListPath();
    final effectiveQuery = endpoint.resolveQueryParams(queryParams);
    return resolve(path, pathParams: pathParams, queryParams: effectiveQuery);
  }
}

/// Resolves endpoint URLs and explicit HTTP verbs for entity operations with strict safety.
class TableEndpointResolver<T> {
  final String entityName;
  final RestEndpoints<T>? endpoints;
  final RestEndpoint? restEndpoint;
  final EndpointUrlResolver urlResolver;

  TableEndpointResolver({
    this.entityName = 'entity',
    String baseUrl = '',
    this.endpoints,
    this.restEndpoint,
  }) : urlResolver = EndpointUrlResolver(baseUrl: baseUrl);

  ({String url, String method}) resolveSave({
    required T item,
    required String id,
    required bool isUpdate,
    Map<String, String>? pathParams,
    Map<String, dynamic>? queryParams,
  }) {
    if (restEndpoint != null) {
      if (isUpdate) {
        final url = urlResolver.resolveUpdateUrl(
          restEndpoint!,
          id,
          pathParams: pathParams,
          queryParams: queryParams,
        );
        return (url: url, method: 'PUT');
      } else {
        final url = urlResolver.resolveCreateUrl(
          restEndpoint!,
          pathParams: pathParams,
          queryParams: queryParams,
        );
        return (url: url, method: 'POST');
      }
    }

    if (isUpdate) {
      if (endpoints?.update == null) {
        throw StateError(
            'Cannot update: No updateEndpoint configured for "$entityName". Orbit refuses un-synced local edits.');
      }
      final req = endpoints!.update!(item);
      final url = urlResolver.resolve(req.path,
          id: id,
          pathParams: pathParams,
          queryParams: queryParams ?? req.queryParams);
      return (url: url, method: req.method.verb);
    }

    if (endpoints?.create == null) {
      throw StateError(
          'Cannot save: No createEndpoint configured for "$entityName". Orbit refuses un-synced local edits.');
    }
    final req = endpoints!.create!(item);
    final url = urlResolver.resolve(req.path,
        id: id,
        pathParams: pathParams,
        queryParams: queryParams ?? req.queryParams);
    return (url: url, method: req.method.verb);
  }

  ({String url, String method}) resolveDelete({
    required String id,
    Map<String, String>? pathParams,
    Map<String, dynamic>? queryParams,
  }) {
    if (restEndpoint != null) {
      final url = urlResolver.resolveDeleteUrl(
        restEndpoint!,
        id,
        pathParams: pathParams,
        queryParams: queryParams,
      );
      return (url: url, method: 'DELETE');
    }

    if (endpoints?.delete == null) {
      throw StateError(
          'Cannot delete: No deleteEndpoint configured for "$entityName". Orbit refuses un-synced local deletions.');
    }
    final req = endpoints!.delete!(id);
    final url = urlResolver.resolve(req.path,
        id: id,
        pathParams: pathParams,
        queryParams: queryParams ?? req.queryParams);
    return (url: url, method: req.method.verb);
  }

  ({String url, String method}) resolveDetail({
    required String id,
    Map<String, String>? pathParams,
    Map<String, dynamic>? queryParams,
  }) {
    if (restEndpoint != null) {
      final url = urlResolver.resolveDetailUrl(
        restEndpoint!,
        id,
        pathParams: pathParams,
        queryParams: queryParams,
      );
      return (url: url, method: 'GET');
    }

    if (endpoints?.getById == null) {
      throw StateError(
          'Cannot fetch detail: No getById configured for "$entityName".');
    }
    final req = endpoints!.getById!(id);
    final url = urlResolver.resolve(req.path,
        id: id,
        pathParams: pathParams,
        queryParams: queryParams ?? req.queryParams);
    return (url: url, method: req.method.verb);
  }

  ({String url, String method}) resolveList({
    Map<String, String>? pathParams,
    Map<String, dynamic>? queryParams,
  }) {
    if (restEndpoint != null) {
      final url = urlResolver.resolveListUrl(
        restEndpoint!,
        pathParams: pathParams,
        queryParams: queryParams,
      );
      return (url: url, method: 'GET');
    }

    if (endpoints?.list == null) {
      throw StateError(
          'Cannot fetch list: No list endpoint configured for "$entityName".');
    }
    final req = endpoints!.list!(queryParams);
    final url = urlResolver.resolve(req.path,
        pathParams: pathParams, queryParams: queryParams ?? req.queryParams);
    return (url: url, method: req.method.verb);
  }

  Future<Map<String, String>?> resolveHeaders(
      [Map<String, String>? additionalHeaders]) async {
    if (restEndpoint != null) {
      final h = await restEndpoint!.resolveHeaders(additionalHeaders);
      return h.isNotEmpty ? h : null;
    }
    if (endpoints?.headers != null || additionalHeaders != null) {
      final res = <String, String>{};
      if (endpoints?.headers != null) res.addAll(endpoints!.headers!);
      if (additionalHeaders != null) res.addAll(additionalHeaders);
      return res.isNotEmpty ? res : null;
    }
    return null;
  }
}
