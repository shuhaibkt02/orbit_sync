import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../storage/sync_storage.dart';
import '../domain/models/client_exceptions.dart';

/// Manages multi-user session filesystem sandboxing, JWT claim assertion,
/// and guest-to-user draft migration (Challenge 5).
class SessionManager {
  const SessionManager();

  String computeSessionPath(String appDir, String userId) {
    final hash = sha256.convert(utf8.encode(userId)).toString().substring(0, 16);
    return '$appDir/orbit_sessions/$hash/orbit.db';
  }

  /// Resolves the physical SQLite database path for isolated users or guest fallback.
  String resolveUserDatabasePath({
    String? databasePath,
    String? appDir,
    String? baseDir,
    String? userId,
  }) {
    if (databasePath != null && databasePath.isNotEmpty) {
      return databasePath;
    }
    final base = appDir ?? baseDir;
    if (base == null || base.isEmpty) {
      throw ArgumentError('Either databasePath or appDir/baseDir must be provided.');
    }
    final cleanBase = base.replaceAll(RegExp(r'[/\\]+$'), '');
    final cleanUser = userId?.trim();
    if (cleanUser != null && cleanUser.isNotEmpty) {
      return '$cleanBase/orbit/users/$cleanUser/orbit.db';
    }
    return '$cleanBase/orbit/guest/orbit.db';
  }

  Future<void> assertTokenSubject({
    required String? token,
    required String expectedUserId,
  }) async {
    if (token == null || token.isEmpty) return;

    final parts = token.split('.');
    if (parts.length != 3) {
      // Non-JWT token (e.g. raw API key or opaque bearer); skip JWT claim assertion
      return;
    }

    try {
      final normalized = base64Url.normalize(parts[1]);
      final payloadJson = utf8.decode(base64Url.decode(normalized));
      final payload = jsonDecode(payloadJson) as Map<String, dynamic>;
      final subject = (payload['sub'] ?? payload['user_id'])?.toString();

      if (subject != null && subject != expectedUserId) {
        throw AuthSubjectMismatchException(
          expectedOwner: expectedUserId,
          actualSubject: subject,
        );
      }
    } catch (e) {
      if (e is AuthSubjectMismatchException) rethrow;
      // Malformed JWT payload, ignore
    }
  }

  Future<int> mergeGuestSession({
    required String guestDatabasePath,
    required String targetDatabasePath,
  }) async {
    final guestStorage = await SyncStorage.open(path: guestDatabasePath);
    final targetStorage = await SyncStorage.open(path: targetDatabasePath);

    try {
      final pendingGuestRows = await guestStorage.db.getAll(
        "SELECT * FROM _sync_outbox WHERE status IN ('pending', 'in_flight') ORDER BY sequence_id ASC",
      );

      if (pendingGuestRows.isEmpty) return 0;

      int mergedCount = 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      await targetStorage.db.writeTransaction((tx) async {
        for (final row in pendingGuestRows) {
          final mutId = row['mutation_id'] as String;
          final entity = row['entity_name'] as String;
          final entityId = row['entity_id'] as String;
          final op = row['op'] as String;
          final payload = row['payload_json'] as String?;
          final endpoint = row['endpoint_url'] as String?;
          final method = row['http_method'] as String?;

          await tx.execute('''
            INSERT OR IGNORE INTO _sync_outbox (
              mutation_id, entity_name, entity_id, op, endpoint_url, 
              http_method, payload_json, base_snapshot_json, base_version,
              status, author_id, user_id, media_path, depends_on_mutation_id,
              correlation_tag, priority, sla_seconds, schema_version,
              error_details_json, dispatch_after, revision_history_json,
              headers_json, retry_count, next_retry_at, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ''', [
            mutId,
            entity,
            entityId,
            op,
            endpoint,
            method,
            payload,
            row['base_snapshot_json'],
            row['base_version'] ?? 1,
            row['author_id'],
            row['user_id'],
            row['media_path'],
            row['depends_on_mutation_id'],
            row['correlation_tag'],
            row['priority'] ?? 0,
            row['sla_seconds'] ?? 86400,
            row['schema_version'] ?? 1,
            row['error_details_json'],
            row['dispatch_after'],
            row['revision_history_json'],
            row['headers_json'],
            row['retry_count'] ?? 0,
            row['next_retry_at'],
            row['created_at'] ?? now,
            now,
          ]);

          // Also transfer domain record if payload exists
          if (payload != null && op != 'delete') {
            try {
              await SqliteSchema.ensureEntityTableExists(tx, {}, entity);
              await tx.execute(
                'INSERT OR REPLACE INTO "$entity" (id, version, updated_at, expires_at, data_json) VALUES (?, 1, ?, NULL, ?)',
                [entityId, now, payload],
              );
            } catch (_) {}
          }
          mergedCount++;
        }

        // Mark guest records as synced so they are not re-pushed
        await guestStorage.db.execute(
          "UPDATE _sync_outbox SET status = 'synced' WHERE status IN ('pending', 'in_flight')",
        );
      });

      return mergedCount;
    } finally {
      await guestStorage.close();
      await targetStorage.close();
    }
  }
}
