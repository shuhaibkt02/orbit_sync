import 'dart:convert';
import 'dart:io';

/// In-process mock sync server for the Orbit Sync example application.
///
/// Runs an ephemeral HTTP server on loopback so the example works out-of-the-box
/// without requiring any external setup, terminal commands, or cloud endpoints.
class MockBackend {
  final HttpServer _server;
  bool isOutage = false;
  final Map<String, Map<String, dynamic>> _storage = {};

  MockBackend._(this._server);

  String get url => 'http://127.0.0.1:${_server.port}';

  static Future<MockBackend> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final backend = MockBackend._(server);
    backend._listen();
    return backend;
  }

  void _listen() {
    _server.listen((HttpRequest req) async {
      if (isOutage) {
        req.response.statusCode = HttpStatus.serviceUnavailable;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'error': 'simulated_outage'}));
        await req.response.close();
        return;
      }

      req.response.headers.contentType = ContentType.json;
      final path = req.uri.path;

      if (req.method == 'POST' && path.endsWith('/sync/push')) {
        final bodyStr = await utf8.decoder.bind(req).join();
        if (bodyStr.isNotEmpty) {
          try {
            final json = jsonDecode(bodyStr) as Map<String, dynamic>;
            final mutations = (json['mutations'] as List?) ?? [];
            for (final m in mutations) {
              if (m is Map<String, dynamic>) {
                final id = m['entity_id']?.toString() ?? m['id']?.toString();
                if (id != null) _storage[id] = m;
              }
            }
          } catch (_) {}
        }
        req.response.statusCode = HttpStatus.ok;
        req.response
            .write(jsonEncode({'status': 'ok', 'applied': _storage.length}));
      } else if (req.method == 'GET' && path.endsWith('/sync/pull')) {
        req.response.statusCode = HttpStatus.ok;
        req.response.write(jsonEncode({
          'changes': _storage.values.toList(),
          'next_cursor': _storage.length,
          'has_more': false,
        }));
      } else if (path.endsWith('/tasks') || path.endsWith('/health')) {
        req.response.statusCode = HttpStatus.ok;
        req.response.write(
            jsonEncode({'status': 'ok', 'items': _storage.values.toList()}));
      } else {
        req.response.statusCode = HttpStatus.ok;
        req.response.write(jsonEncode({'status': 'ok'}));
      }
      await req.response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}
