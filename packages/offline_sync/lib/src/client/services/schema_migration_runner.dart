import 'dart:convert';
import '../../storage/sync_storage.dart';
import '../../consensus/domain/models/sync_result.dart';

/// Runs isolated plugin schema migrations and upgrades outbox envelopes eagerly on startup (Challenge 7).
class SchemaMigrationRunner {
  final SyncStorage storage;
  final int targetSchemaVersion;
  final MutationMigrator? migrator;

  static const String metadataKey = 'orbit_schema_version';

  const SchemaMigrationRunner({
    required this.storage,
    this.targetSchemaVersion = 1,
    this.migrator,
  });

  /// Reads the current stored schema version without touching host app `PRAGMA user_version`.
  Future<int> getCurrentVersion() async {
    final rows = await storage.db.getAll(
      "SELECT value FROM _sync_metadata WHERE key = ?",
      [metadataKey],
    );
    if (rows.isEmpty) return 1;
    return int.tryParse(rows.first['value'] as String? ?? '1') ?? 1;
  }

  /// Sets the recorded plugin schema version in `_sync_metadata`.
  Future<void> setCurrentVersion(int version) async {
    await storage.db.execute(
      "INSERT OR REPLACE INTO _sync_metadata (key, value) VALUES (?, ?)",
      [metadataKey, version.toString()],
    );
  }

  /// Eagerly executes step-ladder migrations on pending outbox mutation envelopes.
  Future<int> runEagerMigrations() async {
    if (migrator == null) return 0;
    final current = await getCurrentVersion();
    if (current >= targetSchemaVersion) return 0;

    int migratedCount = 0;
    await storage.db.writeTransaction((tx) async {
      final rows = await tx.getAll(
        "SELECT * FROM _sync_outbox WHERE status IN ('pending', 'in_flight') AND schema_version < ?",
        [targetSchemaVersion],
      );

      for (final r in rows) {
        final mutId = r['mutation_id'] as String;
        final entity = r['entity_name'] as String;
        final rowVersion = (r['schema_version'] as int?) ?? 1;
        final payloadJson = r['payload_json'] as String?;
        final baseSnapshotJson = r['base_snapshot_json'] as String?;

        if (payloadJson == null) continue;

        var payload = jsonDecode(payloadJson) as Map<String, dynamic>;
        final baseSnapshot = baseSnapshotJson != null
            ? jsonDecode(baseSnapshotJson) as Map<String, dynamic>
            : null;

        // Run step-ladder migration
        var v = rowVersion;
        while (v < targetSchemaVersion) {
          payload = migrator!(v, v + 1, entity, payload);
          v++;
        }

        await tx.execute('''
          UPDATE _sync_outbox SET 
            payload_json = ?, 
            base_snapshot_json = ?, 
            schema_version = ?
          WHERE mutation_id = ?
        ''', [
          jsonEncode(payload),
          baseSnapshot != null ? jsonEncode(baseSnapshot) : null,
          targetSchemaVersion,
          mutId,
        ]);
        migratedCount++;
      }

      await tx.execute(
        "INSERT OR REPLACE INTO _sync_metadata (key, value) VALUES (?, ?)",
        [metadataKey, targetSchemaVersion.toString()],
      );
    });

    return migratedCount;
  }
}
