/// HTTP request description for entity REST integration.
class RestRequest {
  final String path;
  final String method;
  final Map<String, String>? headers;
  final Map<String, dynamic>? queryParams;

  const RestRequest({
    required this.path,
    this.method = 'GET',
    this.headers,
    this.queryParams,
  });
}

/// Declarative REST mapping configuration for typed entity synchronization.
class RestEndpoints<T> {
  final RestRequest Function(Map<String, dynamic> params)? list;
  final List<Map<String, dynamic>> Function(dynamic json)? unwrapList;
  final RestRequest Function(String id)? getById;
  final RestRequest Function(T item)? create;
  final RestRequest Function(T item)? update;
  final RestRequest Function(String id)? delete;

  const RestEndpoints({
    this.list,
    this.unwrapList,
    this.getById,
    this.create,
    this.update,
    this.delete,
  });

  /// Default list unwrapper handling raw JSON array or `{"data": [...]}` envelope.
  static List<Map<String, dynamic>> defaultUnwrap(dynamic json) {
    if (json is List) {
      return json.cast<Map<String, dynamic>>();
    }
    if (json is Map && json['data'] is List) {
      return (json['data'] as List).cast<Map<String, dynamic>>();
    }
    return const [];
  }
}
