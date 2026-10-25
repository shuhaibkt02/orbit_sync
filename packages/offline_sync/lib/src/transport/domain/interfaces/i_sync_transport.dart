import 'dart:async';
import '../models/transport_response.dart';

/// Abstract transport boundary separating local consensus from the transmission wire.
abstract interface class ISyncTransport {
  /// Pushes a batch of mutations to the remote push endpoint.
  Future<TransportResponse> pushBatch({
    required List<Map<String, dynamic>> mutations,
    required String idempotencyKey,
    String? chaos,
  });

  /// Pushes a single mutation to a custom entity endpoint URL.
  /// Outgoing payload contains pure domain data without metadata pollution.
  Future<TransportResponse> pushCustom({
    required String url,
    required String method,
    required String mutationId,
    required int createdAtMs,
    Map<String, dynamic>? payload,
    String? entityId,
  });

  /// Pulls a delta page from the remote pull endpoint.
  Future<TransportResponse> pull({
    required int sinceCursor,
    required int limit,
    Map<String, dynamic>? scopeFilter,
    bool snapshot = false,
    String? chaos,
  });

  /// Optional stream emitted when the remote server signals new changes.
  Stream<void>? get onRemoteChange => null;

  /// Closes underlying connections or resources.
  void dispose() {}
}
