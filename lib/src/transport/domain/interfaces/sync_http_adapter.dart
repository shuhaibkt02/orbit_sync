import '../models/transport_request.dart';
import '../models/transport_response.dart';

/// Pluggable networking abstraction allowing host apps to supply
/// package:http, Dio, or custom corporate mTLS/VPN clients.
abstract interface class SyncHttpAdapter {
  /// Sends the given [request] through the underlying networking client.
  Future<TransportResponse> send(TransportRequest request);

  /// Uploads binary media via multipart/form-data streaming directly from disk path.
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
  }) {
    throw UnsupportedError(
        'pushMultipart is not supported by $runtimeType. Use DioHttpAdapter.');
  }

  /// Releases underlying connection pools or resources.
  void dispose() {}
}
