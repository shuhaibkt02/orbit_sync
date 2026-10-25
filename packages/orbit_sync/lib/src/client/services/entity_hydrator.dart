import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../../storage/sync_storage.dart';
import '../domain/policies/sqlite_type_sanitizer.dart';

/// Hydrates local offline storage from remote collections while
/// strictly protecting unpushed offline edits from ghost rollbacks (Challenge 1).
class EntityHydrator {
  final SyncStorage storage;
  final SqliteTypeSanitizer sanitizer;

  const EntityHydrator({
    required this.storage,
    this.sanitizer = const SqliteTypeSanitizer(),
  });

  /// Fetches collection from remote REST URL and hydrates cleanly.
  Future<int> fetchAndStore(
    String entity, {
    required String url,
    Map<String, String>? headers,
    Future<String?> Function()? getAuthToken,
    http.Client? httpClient,
  }) async {
    final req = http.Request('GET', Uri.parse(url));
    req.headers['content-type'] = 'application/json';
    if (getAuthToken != null) {
      final token = await getAuthToken();
      if (token != null) req.headers['authorization'] = 'Bearer $token';
    }
    if (headers != null) req.headers.addAll(headers);

    final client = httpClient ?? http.Client();
    try {
      final streamed = await client.send(req);
      final resp = await http.Response.fromStream(streamed);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw HttpException('Failed to hydrate $entity: HTTP ${resp.statusCode}');
      }
      final decoded = jsonDecode(resp.body);
      final List<dynamic> items = decoded is List ? decoded : (decoded['data'] as List? ?? []);
      return await hydrateBatch(entity: entity, items: items.cast<Map<String, dynamic>>());
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// Hydrates a batch of remote server records into the local [entity] table.
  ///
  /// Guarantees serializability (ACID S): If an item has an active outbox mutation
  /// in 'pending' or 'in_flight' status, the local domain row is shielded from
  /// overwrite, and its outbox baseline snapshot is atomically updated instead.
  Future<int> hydrateBatch({
    required String entity,
    required List<Map<String, dynamic>> items,
    String primaryKey = 'id',
  }) async {
    if (items.isEmpty) return 0;

    return await storage.db.writeTransaction<int>((tx) async {
      int insertedOrUpdated = 0;
      final now = DateTime.now().millisecondsSinceEpoch;

      for (final rawItem in items) {
        final sanitized = sanitizer.sanitizeMap(rawItem);
        final id = (sanitized[primaryKey] ?? sanitized['id'])?.toString();
        if (id == null) continue;

        if (sanitized['updated_at'] == null) sanitized['updated_at'] = now;
        if (sanitized['version'] == null) sanitized['version'] = 1;

        for (final entry in sanitized.entries) {
          if (entry.key != primaryKey && entry.key != 'id' && entry.key != 'version' && entry.key != 'updated_at') {
            try {
              final type = sanitizer.inferColumnType(entry.value);
              await tx.execute('ALTER TABLE $entity ADD COLUMN ${entry.key} $type');
            } catch (_) {}
          }
        }

        final outboxRows = await tx.getAll(
          "SELECT mutation_id, status FROM _sync_outbox WHERE entity_name = ? AND entity_id = ? AND status IN ('pending', 'in_flight') LIMIT 1",
          [entity, id],
        );

        if (outboxRows.isNotEmpty) {
          final mutationId = outboxRows.first['mutation_id'] as String;
          await tx.execute(
            'UPDATE _sync_outbox SET base_snapshot_json = ? WHERE mutation_id = ?',
            [jsonEncode(rawItem), mutationId],
          );
          continue;
        }

        final cols = <String>[primaryKey];
        final vals = <dynamic>[id];
        final updates = <String>[];

        for (final entry in sanitized.entries) {
          if (entry.key != primaryKey && entry.key != 'id') {
            cols.add(entry.key);
            vals.add(entry.value);
            updates.add('${entry.key} = excluded.${entry.key}');
          }
        }

        final colStr = cols.join(', ');
        final placeholders = List.filled(cols.length, '?').join(', ');
        final updateClause = updates.isNotEmpty ? updates.join(', ') : '$primaryKey = excluded.$primaryKey';

        final sql = '''
          INSERT INTO $entity ($colStr) VALUES ($placeholders)
          ON CONFLICT($primaryKey) DO UPDATE SET $updateClause
        ''';

        await tx.execute(sql, vals);
        insertedOrUpdated++;
      }

      return insertedOrUpdated;
    });
  }
}
