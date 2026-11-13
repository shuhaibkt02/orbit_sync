import 'dart:convert';
import 'dart:io';

sealed class BatchItemOutcome {
  final String itemId;
  const BatchItemOutcome(this.itemId);
}

class Accept extends BatchItemOutcome {
  const Accept(String itemId) : super(itemId);
}

class Reject extends BatchItemOutcome {
  final int status;
  final String reason;
  const Reject(String itemId, {this.status = 422, this.reason = 'Rejected'}) : super(itemId);
}

/// Helper that runs an in-memory HTTP server scripted for item-by-item batch outcomes.
class ScriptedBatchServer {
  final HttpServer _server;
  final Map<String, BatchItemOutcome> _outcomes = {};
  final List<String> receivedItemIds = [];
  final Map<String, int> acceptedCounts = {};

  ScriptedBatchServer._(this._server);

  static Future<ScriptedBatchServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = ScriptedBatchServer._(server);
    server.listen(instance._handleRequest);
    return instance;
  }

  String get url => 'http://${_server.address.address}:${_server.port}/api/work_orders';

  void scriptItem(BatchItemOutcome outcome) {
    _outcomes[outcome.itemId] = outcome;
  }

  void scriptAll(Iterable<BatchItemOutcome> outcomes) {
    for (final o in outcomes) {
      _outcomes[o.itemId] = o;
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final bodyStr = await utf8.decoder.bind(request).join();
    final body = bodyStr.isNotEmpty ? (jsonDecode(bodyStr) as Map<String, dynamic>) : <String, dynamic>{};
    final id = (body['id'] as String?) ?? request.headers.value('x-entity-id') ?? request.headers.value('X-Entity-ID') ?? request.uri.pathSegments.last;
    receivedItemIds.add(id);

    final outcome = _outcomes[id];
    if (outcome is Reject) {
      request.response.statusCode = outcome.status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': 'validation_error',
        'detail': outcome.reason,
      }));
      await request.response.close();
      return;
    }

    acceptedCounts[id] = (acceptedCounts[id] ?? 0) + 1;
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'status': 'ok', 'id': id}));
    await request.response.close();
  }

  Future<void> close() => _server.close(force: true);
}
