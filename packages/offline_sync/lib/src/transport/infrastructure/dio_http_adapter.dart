import 'package:dio/dio.dart';
import '../domain/interfaces/sync_http_adapter.dart';
import '../domain/models/transport_request.dart';
import '../domain/models/transport_response.dart';

/// Enterprise HTTP adapter utilizing [Dio] for advanced interceptors,
/// proxy configuration, and corporate SSL pinning.
class DioHttpAdapter implements SyncHttpAdapter {
  final Dio _dio;
  final bool _isOwned;

  DioHttpAdapter({Dio? dio})
      : _dio = dio ?? Dio(),
        _isOwned = dio == null;

  /// Underlying [Dio] instance.
  Dio get dio => _dio;

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    try {
      final options = Options(
        method: request.method,
        headers: request.headers,
        responseType: ResponseType.plain,
        sendTimeout: request.connectTimeout,
        receiveTimeout: request.readTimeout,
        validateStatus: (_) => true, // Forward all status codes cleanly
      );

      final response = await _dio.request<String>(
        request.uri.toString(),
        data: request.body,
        options: options,
      );

      final headersMap = <String, String>{};
      response.headers.forEach((key, values) {
        headersMap[key] = values.join(',');
      });

      return TransportResponse(
        statusCode: response.statusCode ?? 0,
        body: response.data ?? '',
        headers: headersMap,
      );
    } on DioException catch (e) {
      final headersMap = <String, String>{};
      e.response?.headers.forEach((key, values) {
        headersMap[key] = values.join(',');
      });

      return TransportResponse(
        statusCode: e.response?.statusCode ?? 0,
        body: e.response?.data?.toString() ?? '',
        headers: headersMap,
        error: e,
      );
    } catch (e) {
      return TransportResponse(statusCode: 0, error: e);
    }
  }

  @override
  void dispose() {
    if (_isOwned) {
      _dio.close(force: true);
    }
  }
}
