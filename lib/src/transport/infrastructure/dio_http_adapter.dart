import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import '../domain/interfaces/sync_http_adapter.dart';
import '../domain/models/transport_request.dart';
import '../domain/models/transport_response.dart';
import '../domain/policies/payload_sanitizer.dart' as sanitizer;

/// Enterprise HTTP adapter utilizing [Dio] for advanced interceptors,
/// proxy configuration, corporate SSL pinning, and standard split timeouts.
class DioHttpAdapter implements SyncHttpAdapter {
  final Dio _dio;
  final bool _isOwned;

  DioHttpAdapter({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 3),
                receiveTimeout: const Duration(seconds: 15),
              ),
            ),
        _isOwned = dio == null;

  /// Underlying [Dio] instance.
  Dio get dio => _dio;

  /// Helper to sanitize payloads removing internal sync and offline flags.
  static Map<String, dynamic> sanitizePayload(Map<String, dynamic> payload) =>
      sanitizer.sanitizePayload(payload);

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    try {
      final reqHeaders =
          CanonicalizedMap<String, String, dynamic>((k) => k.toLowerCase());
      reqHeaders.addAll(request.headers);

      final isMutating = const {'POST', 'PUT', 'PATCH', 'DELETE'}
          .contains(request.method.toUpperCase());
      if (isMutating &&
          request.mutationId != null &&
          !reqHeaders.containsKey('Idempotency-Key')) {
        reqHeaders['Idempotency-Key'] = request.mutationId;
      }

      final options = Options(
        method: request.method,
        headers: reqHeaders,
        responseType: ResponseType.plain,
        sendTimeout: request.connectTimeout,
        receiveTimeout: request.readTimeout,
        validateStatus: (code) => code != null && code < 400,
      );

      final response = await _dio.request<String>(
        request.uri.toString(),
        data: request.body,
        options: options,
      );

      final headersMap =
          CanonicalizedMap<String, String, String>((key) => key.toLowerCase());
      response.headers.forEach((key, values) {
        headersMap[key] = values.join(',');
      });

      return TransportResponse(
        statusCode: response.statusCode ?? 0,
        body: response.data ?? '',
        headers: headersMap,
      );
    } on DioException catch (e) {
      final headersMap =
          CanonicalizedMap<String, String, String>((key) => key.toLowerCase());
      e.response?.headers.forEach((key, values) {
        headersMap[key] = values.join(',');
      });

      return TransportResponse(
        statusCode: e.response?.statusCode ?? 0,
        body: e.response?.data?.toString() ?? '',
        headers: headersMap,
        error: e.type == DioExceptionType.badResponse ? null : e,
      );
    } catch (e) {
      return TransportResponse(statusCode: 0, error: e);
    }
  }

  /// Uploads binary media via multipart/form-data streaming directly from disk path.
  /// Streams binary chunks from disk without reading the full file bytes into RAM (`Uint8List`).
  @override
  Future<TransportResponse> pushMultipart({
    required Uri uri,
    String method = 'POST',
    required String fieldName,
    required String filePath,
    String? fileName,
    String? mimeType,
    Map<String, dynamic>? extraFields,
    Map<String, String>? headers,
    Duration? timeout,
    void Function(int sent, int total)? onSendProgress,
  }) async {
    try {
      final reqHeaders =
          CanonicalizedMap<String, String, dynamic>((k) => k.toLowerCase());
      if (headers != null) {
        reqHeaders.addAll(headers);
      }
      if (reqHeaders['content-type'] == 'application/json') {
        reqHeaders.remove('content-type');
      }

      final formMap = <String, dynamic>{};
      if (extraFields != null) {
        final cleanFields = sanitizer.sanitizePayload(extraFields);
        formMap.addAll(cleanFields);
      }

      final multipartFile = await MultipartFile.fromFile(
        filePath,
        filename: fileName,
        contentType: mimeType != null ? DioMediaType.parse(mimeType) : null,
      );
      formMap[fieldName] = multipartFile;

      final formData = FormData.fromMap(formMap);

      final effectiveTimeout = timeout ?? const Duration(seconds: 60);
      final options = Options(
        method: method,
        headers: reqHeaders,
        responseType: ResponseType.plain,
        sendTimeout: effectiveTimeout,
        receiveTimeout: effectiveTimeout,
        validateStatus: (code) => code != null && code < 400,
      );

      final response = await _dio.request<String>(
        uri.toString(),
        data: formData,
        options: options,
        onSendProgress: onSendProgress,
      );

      final headersMap =
          CanonicalizedMap<String, String, String>((key) => key.toLowerCase());
      response.headers.forEach((key, values) {
        headersMap[key] = values.join(',');
      });

      return TransportResponse(
        statusCode: response.statusCode ?? 0,
        body: response.data ?? '',
        headers: headersMap,
      );
    } on DioException catch (e) {
      final headersMap =
          CanonicalizedMap<String, String, String>((key) => key.toLowerCase());
      e.response?.headers.forEach((key, values) {
        headersMap[key] = values.join(',');
      });

      return TransportResponse(
        statusCode: e.response?.statusCode ?? 0,
        body: e.response?.data?.toString() ?? '',
        headers: headersMap,
        error: e.type == DioExceptionType.badResponse ? null : e,
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
