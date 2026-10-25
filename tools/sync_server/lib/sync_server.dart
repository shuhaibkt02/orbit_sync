import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Minimal in-memory sync server implementing the sync contract and chaos flags.
class FakeSyncServer {
  final HttpServer server;
  int retentionCursor = 0;
  int minSchemaVersion = 1;
  int cursor = 0;
  final Map<String, Map<String, dynamic>> records = {};
  final List<Map<String, dynamic>> changelog = [];
  final Map<String, Map<String, dynamic>> idempotencyCache = {};

  FakeSyncServer._(this.server);

  int get port => server.port;
  String get baseUrl => 'http://127.0.0.1:$port';

  static Future<FakeSyncServer> start({int port = 0, int retentionCursor = 0}) async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    final instance = FakeSyncServer._(server);
    instance.retentionCursor = retentionCursor;
    instance._listen();
    return instance;
  }

  void reset({int newRetentionCursor = 0}) {
    cursor = 0;
    records.clear();
    changelog.clear();
    idempotencyCache.clear();
    retentionCursor = newRetentionCursor;
  }

  void _listen() {
    server.listen((HttpRequest request) async {
      try {
        final path = request.uri.path;
        final chaos = request.uri.queryParameters['chaos'];

        if (request.method == 'POST' && path == '/test/reset') {
          final retention = int.tryParse(request.uri.queryParameters['retention_cursor'] ?? '') ?? 0;
          reset(newRetentionCursor: retention);
          _sendJson(request.response, HttpStatus.ok, {'status': 'reset', 'retention_cursor': retention});
          return;
        }

        if (request.method == 'GET' && path == '/health') {
          _sendJson(request.response, HttpStatus.ok, {'status': 'ok'});
          return;
        }

        if (path == '/orders' || path == '/tasks' || path == '/') {
          if (request.method == 'POST') {
            final bodyStr = await utf8.decoder.bind(request).join();
            final data = bodyStr.isNotEmpty ? jsonDecode(bodyStr) as Map<String, dynamic> : <String, dynamic>{};
            final entity = path == '/' ? 'tasks' : path.substring(1);
            final id = data['id']?.toString() ?? '$entity-${records.length}';
            records['$entity:$id'] = data;
            _sendJson(request.response, HttpStatus.created, {'id': id, 'status': 'created'});
            return;
          }
          if (request.method == 'GET') {
            final entity = path == '/' ? 'tasks' : path.substring(1);
            final entityList = records.entries
                .where((e) => e.key.startsWith('$entity:'))
                .map((e) => e.value)
                .toList();
            _sendJson(request.response, HttpStatus.ok, {'items': entityList, 'count': entityList.length});
            return;
          }
        }

        if (request.method == 'POST' && path == '/sync/push') {
          if (chaos == 'unauthorized' || request.headers.value('Authorization') == 'Bearer expired') {
            _sendJson(request.response, HttpStatus.unauthorized, {
              'error': 'unauthorized',
              'detail': 'Access token expired or invalid',
            });
            return;
          }

          if (chaos == 'bad_request') {
            _sendJson(request.response, HttpStatus.badRequest, {
              'error': 'bad_request',
              'detail': 'Malformed mutation envelope',
            });
            return;
          }

          if (chaos == 'conflict') {
            _sendJson(request.response, HttpStatus.conflict, {
              'error': 'conflict',
              'server_version': 2,
              'details': 'Record was modified concurrently on server'
            });
            return;
          }

          if (chaos == 'validation_error') {
            _sendJson(request.response, HttpStatus.unprocessableEntity, {
              'type': 'https://offline-sync.dev/errors/validation',
              'title': 'Unprocessable Entity',
              'status': 422,
              'detail': 'Provided payload failed business invariant validation',
              'invalid_params': [
                {'name': 'title', 'reason': 'must not be blank'}
              ]
            });
            return;
          }

          final bodyStr = await utf8.decoder.bind(request).join();
          final dynamic body = bodyStr.isNotEmpty ? jsonDecode(bodyStr) : {};
          final List<dynamic> rawMutations = body is List ? body : (body['mutations'] as List? ?? []);
          final mutations = rawMutations.cast<Map<String, dynamic>>();

          if (mutations.any((m) => m['id'] == 'poison-pill' || (m['payload'] is Map && m['payload']['customer'] == 'poison-pill'))) {
            _sendJson(request.response, HttpStatus.badRequest, {
              'error': 'bad_request',
              'detail': 'Poison pill rejected by schema validator'
            });
            return;
          }

          // Minimum schema version floor check (HTTP 426)
          if (mutations.any((m) => ((m['schema_version'] as int?) ?? 1) < minSchemaVersion)) {
            _sendJson(request.response, HttpStatus.upgradeRequired, {
              'error': 'client_too_old',
              'detail': 'Schema version $minSchemaVersion required, older client schema rejected'
            });
            return;
          }

          // Foreign key integrity check: parent must exist on server
          for (final mut in mutations) {
            final payload = (mut['payload'] as Map<String, dynamic>?) ?? {};
            final orderId = payload['order_id'];
            if (mut['entity'] == 'order_items' && orderId != null) {
              final parentExists = records.containsKey('orders:$orderId') ||
                  mutations.any((m) => m['entity'] == 'orders' && m['id'].toString() == orderId.toString());
              if (!parentExists) {
                _sendJson(request.response, HttpStatus.badRequest, {
                  'error': 'foreign_key_violation',
                  'detail': 'Parent order $orderId not found on server'
                });
                return;
              }
            }
          }

          final idempotencyKey = request.headers.value('Idempotency-Key');

          // Idempotent deduplication check
          if (idempotencyKey != null && idempotencyCache.containsKey(idempotencyKey)) {
            final cached = idempotencyCache[idempotencyKey]!;
            _sendJson(request.response, HttpStatus.ok, cached);
            return;
          }

          // Apply mutations to store
          for (final mut in mutations) {
            cursor++;
            final entity = mut['entity'] as String? ?? 'default';
            final id = mut['id'].toString();
            final op = mut['op'] as String? ?? 'upsert';
            final payload = (mut['payload'] as Map<String, dynamic>?) ?? {};
            final version = mut['version'] ?? 1;

            final key = '$entity:$id';
            if (op == 'delete') {
              records.remove(key);
              changelog.add({
                'cursor': cursor,
                'entity': entity,
                'id': id,
                'op': 'delete',
                '_deleted': true,
                'data': null,
                'version': version,
              });
            } else {
              records[key] = payload;
              changelog.add({
                'cursor': cursor,
                'entity': entity,
                'id': id,
                'op': op,
                '_deleted': false,
                'data': payload,
                'version': version,
              });
            }
          }

          final responsePayload = {
            'status': 'ok',
            'applied': mutations.length,
            'server_cursor': cursor,
            'deduplicated': false,
          };

          if (idempotencyKey != null) {
            final cached = Map<String, dynamic>.from(responsePayload);
            cached['deduplicated'] = true;
            idempotencyCache[idempotencyKey] = cached;
          }

          // Chaos: abruptly drop TCP socket without sending headers (Two Generals' test)
          if (chaos == 'drop_before_response') {
            final socket = await request.response.detachSocket();
            socket.destroy();
            return;
          }

          _sendJson(request.response, HttpStatus.ok, responsePayload);
          return;
        }

        if (request.method == 'GET' && path == '/sync/pull') {
          if (chaos == 'expired_cursor') {
            _sendJson(request.response, HttpStatus.gone, {
              'error': 'cursor_expired',
              'detail': 'Cursor falls behind compaction retention window; full resync required'
            });
            return;
          }

          final isSnapshot = request.uri.queryParameters['snapshot'] == 'true';
          if (isSnapshot) {
            final snapshotChanges = records.entries.map((e) {
              final parts = e.key.split(':');
              return {
                'cursor': cursor,
                'entity': parts[0],
                'id': parts[1],
                'op': 'upsert',
                '_deleted': false,
                'data': e.value,
                'version': 1,
              };
            }).toList();
            _sendJson(request.response, HttpStatus.ok, {
              'changes': snapshotChanges,
              'next_cursor': cursor,
              'has_more': false,
            });
            return;
          }

          final since = int.tryParse(request.uri.queryParameters['since'] ?? '') ?? 0;
          final limit = int.tryParse(request.uri.queryParameters['limit'] ?? '') ?? 50;
          final scopeStr = request.uri.queryParameters['scope'];
          final Map<String, dynamic>? scope = scopeStr != null ? jsonDecode(scopeStr) : null;

          if (since < retentionCursor) {
            _sendJson(request.response, HttpStatus.gone, {
              'error': 'cursor_expired',
              'detail': 'Requested cursor has been purged from changelog'
            });
            return;
          }

          final changes = changelog.where((c) => (c['cursor'] as int) > since).toList();
          final page = changes.take(limit).toList();
          final hasMore = changes.length > limit;
          final nextCursor = page.isNotEmpty ? page.last['cursor'] : since;

          final List<Map<String, dynamic>> outChanges = [];
          for (final c in page) {
            final item = Map<String, dynamic>.from(c);
            if (scope != null && item['_deleted'] != true) {
              final data = (item['data'] as Map<String, dynamic>?) ?? {};
              bool inScope = true;
              for (final entry in scope.entries) {
                if (data[entry.key]?.toString() != entry.value?.toString()) {
                  inScope = false;
                  break;
                }
              }
              if (!inScope) {
                item['left_scope'] = true;
                item['data'] = null;
              }
            }
            outChanges.append(item);
          }

          _sendJson(request.response, HttpStatus.ok, {
            'changes': outChanges,
            'next_cursor': nextCursor,
            'has_more': hasMore,
          });
          return;
        }

        _sendJson(request.response, HttpStatus.notFound, {'error': 'not_found'});
      } catch (e) {
        try {
          _sendJson(request.response, HttpStatus.internalServerError, {'error': e.toString()});
        } catch (_) {}
      }
    });
  }

  void _sendJson(HttpResponse response, int statusCode, Map<String, dynamic> body) {
    final bytes = utf8.encode(jsonEncode(body));
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.headers.contentLength = bytes.length;
    response.add(bytes);
    response.close();
  }

  Future<void> stop() async {
    await server.close(force: true);
  }
}

extension on List<Map<String, dynamic>> {
  void append(Map<String, dynamic> item) => add(item);
}
