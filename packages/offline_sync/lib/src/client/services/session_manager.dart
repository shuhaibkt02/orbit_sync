import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../storage/sync_storage.dart';
import '../domain/interfaces/i_session_manager.dart';
import '../domain/models/client_exceptions.dart';

/// Manages multi-user session filesystem sandboxing, JWT claim assertion,
/// and guest-to-user draft migration (Challenge 5).
class SessionManager implements ISessionManager {
  const SessionManager();

  @override
  String computeSessionPath(String appDir, String userId) {
    final hash = sha256.convert(utf8.encode(userId)).toString().substring(0, 16);
    return '$appDir/orbit_sessions/$hash/orbit.db';
  }

  @override
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

  @override
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
              mutation_id, entity_name, entity_id, op, payload_json, 
              endpoint_url, http_method, status, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?)
          ''', [
            mutId,
            entity,
            entityId,
            op,
            payload,
            endpoint,
            method,
            DateTime.now().millisecondsSinceEpoch,
          ]);

          // Also transfer domain record if payload exists
          if (payload != null && op != 'delete') {
            try {
              final data = jsonDecode(payload) as Map<String, dynamic>;
              final cols = <String>['id'];
              final vals = <dynamic>[entityId];
              for (final e in data.entries) {
                if (e.key != 'id') {
                  cols.add(e.key);
                  vals.add(e.value?.toString());
                  try {
                    await tx.execute('ALTER TABLE $entity ADD COLUMN ${e.key} TEXT');
                  } catch (_) {}
                }
              }
              final colStr = cols.join(', ');
              final placeholders = List.filled(cols.length, '?').join(', ');
              await tx.execute('INSERT OR REPLACE INTO $entity ($colStr) VALUES ($placeholders)', vals);
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
