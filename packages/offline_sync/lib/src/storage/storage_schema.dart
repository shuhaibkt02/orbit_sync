import 'package:sqlite_async/sqlite_async.dart';
import 'sync_validator.dart';

/// Manages SQLite system table schemas, indices, and entity table creation.
class StorageSchema {
  static const systemEntityCols = {
    'id',
    'version',
    'updated_at',
    'expires_at',
    '_base_snapshot_json',
    'data_json',
  };

  /// Initializes system tables: _sync_outbox, _sync_id_map, and _sync_metadata
  static Future<void> initSystemSchema(SqliteDatabase db) async {
    await db.writeTransaction((tx) async {
      await tx.execute('''
        CREATE TABLE IF NOT EXISTS _sync_outbox (
          sequence_id INTEGER PRIMARY KEY AUTOINCREMENT,
          mutation_id TEXT UNIQUE NOT NULL,
          entity_name TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          op TEXT NOT NULL,
          endpoint_url TEXT,
          http_method TEXT,
          payload_json TEXT,
          base_snapshot_json TEXT,
          base_version INTEGER NOT NULL DEFAULT 1 CHECK (base_version >= 1),
          status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'in_flight', 'synced', 'failed', 'dlq', 'held', 'conflict')),
          depends_on_mutation_id TEXT,
          correlation_tag TEXT,
          priority INTEGER NOT NULL DEFAULT 0 CHECK (priority BETWEEN 0 AND 2),
          sla_seconds INTEGER DEFAULT 86400 CHECK (sla_seconds >= 0),
          schema_version INTEGER NOT NULL DEFAULT 1 CHECK (schema_version >= 1),
          error_details_json TEXT,
          dispatch_after INTEGER,
          revision_history_json TEXT,
          retry_count INTEGER NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
          next_retry_at INTEGER,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL DEFAULT 0
        );
      ''');

      // Startup recovery: Reset stranded in_flight records from interrupted sessions
      try {
        await tx.execute("UPDATE _sync_outbox SET status = 'pending' WHERE status = 'in_flight';");
      } catch (_) {}

      await tx.execute('''
        CREATE INDEX IF NOT EXISTS idx_sync_outbox_queue 
        ON _sync_outbox(status, dispatch_after, next_retry_at, priority DESC, sequence_id ASC);
      ''');

      await tx.execute('''
        CREATE INDEX IF NOT EXISTS idx_sync_outbox_sla 
        ON _sync_outbox(status, (created_at + sla_seconds * 1000) ASC, priority DESC);
      ''');

      await tx.execute('''
        CREATE INDEX IF NOT EXISTS idx_sync_outbox_entity 
        ON _sync_outbox(entity_name, entity_id, status);
      ''');

      await tx.execute('''
        CREATE INDEX IF NOT EXISTS idx_sync_outbox_deps 
        ON _sync_outbox(depends_on_mutation_id);
      ''');

      await tx.execute('''
        CREATE TABLE IF NOT EXISTS _sync_id_map (
          entity_name TEXT NOT NULL,
          local_temp_id TEXT NOT NULL,
          canonical_server_id TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          PRIMARY KEY (entity_name, local_temp_id)
        );
      ''');

      await tx.execute('''
        CREATE INDEX IF NOT EXISTS idx_sync_id_map_canonical 
        ON _sync_id_map(entity_name, canonical_server_id);
      ''');

      await tx.execute('''
        CREATE TABLE IF NOT EXISTS _sync_metadata (
          key TEXT PRIMARY KEY,
          value TEXT
        );
      ''');
    });
  }

  /// Registers an entity table with custom columns and optional foreign key clauses.
  static Future<void> registerEntityTable(
    SqliteDatabase db,
    Set<String> knownColumns,
    String entityName,
    Map<String, String> columnTypes, {
    String? foreignKeyClause,
  }) async {
    SyncValidator.validateEntity(entityName);
    final colDefs = columnTypes.entries.map((e) => '"${e.key}" ${e.value}').join(', ');
    final fullCols = colDefs.isNotEmpty ? ', $colDefs' : '';
    final fk = foreignKeyClause != null ? ', $foreignKeyClause' : '';

    await db.execute('''
      CREATE TABLE IF NOT EXISTS "$entityName" (
        "id" TEXT PRIMARY KEY,
        "version" INTEGER NOT NULL DEFAULT 1 CHECK ("version" >= 1),
        "updated_at" INTEGER NOT NULL,
        "expires_at" INTEGER,
        "_base_snapshot_json" TEXT,
        "data_json" TEXT NOT NULL DEFAULT '{}'
        $fullCols
        $fk
      );
    ''');

    knownColumns.addAll([
      '$entityName:id',
      '$entityName:version',
      '$entityName:updated_at',
      '$entityName:expires_at',
      '$entityName:_base_snapshot_json',
      '$entityName:data_json',
    ]);
    for (final col in columnTypes.keys) {
      knownColumns.add('$entityName:$col');
    }
  }

  /// Ensures default dynamic table and its expires_at index exist.
  static Future<void> ensureEntityTableExists(
    SqliteWriteContext tx,
    Set<String> knownColumns,
    String entity,
  ) async {
    if (knownColumns.contains('$entity:id')) return;

    await tx.execute('''
      CREATE TABLE IF NOT EXISTS "$entity" (
        "id" TEXT PRIMARY KEY,
        "version" INTEGER NOT NULL DEFAULT 1 CHECK ("version" >= 1),
        "updated_at" INTEGER NOT NULL,
        "expires_at" INTEGER,
        "_base_snapshot_json" TEXT,
        "data_json" TEXT NOT NULL DEFAULT '{}'
      );
    ''');

    await tx.execute('''
      CREATE INDEX IF NOT EXISTS "idx_${entity}_expires" ON "$entity"("expires_at");
    ''');

    knownColumns.addAll([
      '$entity:id',
      '$entity:version',
      '$entity:updated_at',
      '$entity:expires_at',
      '$entity:_base_snapshot_json',
      '$entity:data_json',
    ]);
  }
}
