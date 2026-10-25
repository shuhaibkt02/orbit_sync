import '../models/transport_request.dart';
import '../models/transport_response.dart';

/// Pluggable networking abstraction allowing host apps to supply
/// package:http, Dio, or custom corporate mTLS/VPN clients.
abstract interface class SyncHttpAdapter {
  /// Sends the given [request] through the underlying networking client.
  Future<TransportResponse> send(TransportRequest request);

  /// Releases underlying connection pools or resources.
  void dispose() {}
}
