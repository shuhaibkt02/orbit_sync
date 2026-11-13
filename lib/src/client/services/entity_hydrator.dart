import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../../storage/sync_storage.dart';
import '../../storage/infrastructure/sqlite/sqlite_cache_cleaner.dart';
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
    Future<String> Function(String url, Map<String, String>? headers)? customFetcher,
  }) async {
    final Map<String, String> reqHeaders = {'content-type': 'application/json'};
    if (getAuthToken != null) {
      final token = await getAuthToken();
      if (token != null) reqHeaders['authorization'] = token.startsWith('Bearer ') ? token : 'Bearer $token';
    }
    if (headers != null) reqHeaders.addAll(headers);

    if (customFetcher != null) {
      final body = await customFetcher(url, reqHeaders);
      final decoded = jsonDecode(body);
      final List<dynamic> items = decoded is List ? decoded : (decoded['data'] as List? ?? []);
      return await hydrateBatch(entity: entity, items: items.cast<Map<String, dynamic>>());
    }

    final req = http.Request('GET', Uri.parse(url));
    req.headers.addAll(reqHeaders);

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
    int? maxCacheRecords,
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

        final outboxRows = await tx.getAll(
          "SELECT mutation_id, status FROM _sync_outbox WHERE entity_name = ? AND entity_id = ? AND status IN ('pending', 'in_flight', 'held', 'validation_error') ORDER BY sequence_id ASC LIMIT 1",
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

        final version = sanitized['version'] is int ? sanitized['version'] as int : 1;
        final updatedAt = sanitized['updated_at'] is int ? sanitized['updated_at'] as int : now;
        final expiresAt = sanitized['expires_at'] is int ? sanitized['expires_at'] as int : null;
        final dataJson = jsonEncode(rawItem);

        await tx.execute('''
          INSERT INTO "$entity" ("id", "version", "updated_at", "expires_at", "data_json")
          VALUES (?, ?, ?, ?, ?)
          ON CONFLICT("id") DO UPDATE SET
            "version" = excluded."version",
            "updated_at" = excluded."updated_at",
            "expires_at" = excluded."expires_at",
            "data_json" = excluded."data_json"
        ''', [id, version, updatedAt, expiresAt, dataJson]);
        insertedOrUpdated++;
      }

      if (maxCacheRecords != null && maxCacheRecords > 0) {
        await SqliteCacheCleaner.pruneToQuotaTx(tx, entity, maxCacheRecords: maxCacheRecords);
      }

      return insertedOrUpdated;
    });
  }
}
