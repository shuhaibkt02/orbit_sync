import 'dart:async';
import 'dart:convert';
import 'package:sqlite3/sqlite3.dart' show ResultSet;
import 'package:sqlite_async/sqlite_async.dart';
import 'uuid_v7.dart';

/// Manages local SQLite storage with WAL mode, dedicated writer isolate,
/// transactional outbox, shadow-base materialization, and reactive streams.
class SyncStorage {
  final SqliteDatabase db;
  final String path;

  SyncStorage._(this.db, this.path);

  /// Opens or creates database at [path] with connection pooling.
  static Future<SyncStorage> open({
    required String path,
    int maxReaders = 4,
  }) async {
    final db = SqliteDatabase(
      path: path,
      maxReaders: maxReaders,
    );
    await db.initialize();

    final storage = SyncStorage._(db, path);
    await storage._initSystemSchema();
    return storage;
  }

  /// Initializes system tables: _sync_outbox and _sync_metadata
  Future<void> _initSystemSchema() async {
    await db.writeTransaction((tx) async {
      await tx.execute('''
        CREATE TABLE IF NOT EXISTS _sync_outbox (
          mutation_id TEXT PRIMARY KEY,
          entity_name TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          op TEXT NOT NULL,
          endpoint_url TEXT,
          http_method TEXT,
          payload_json TEXT,
          base_snapshot_json TEXT,
          base_version INTEGER NOT NULL DEFAULT 1,
          status TEXT NOT NULL DEFAULT 'pending',
          depends_on_mutation_id TEXT,
          schema_version INTEGER NOT NULL DEFAULT 1,
          error_details_json TEXT,
          retry_count INTEGER NOT NULL DEFAULT 0,
          created_at INTEGER NOT NULL
        );
      ''');

      // Ensure backward-compatible column upgrades if table existed
      try {
        await tx.execute('ALTER TABLE _sync_outbox ADD COLUMN endpoint_url TEXT');
      } catch (_) {}
      try {
        await tx.execute('ALTER TABLE _sync_outbox ADD COLUMN http_method TEXT');
      } catch (_) {}

      await tx.execute('''
        CREATE INDEX IF NOT EXISTS idx_sync_outbox_queue 
        ON _sync_outbox(status, created_at);
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
  Future<void> registerEntityTable(
    String entityName,
    Map<String, String> columnTypes, {
    String? foreignKeyClause,
  }) async {
    final colDefs = columnTypes.entries.map((e) => '${e.key} ${e.value}').join(', ');
    final fullCols = colDefs.isNotEmpty ? ', $colDefs' : '';
    final fk = foreignKeyClause != null ? ', $foreignKeyClause' : '';

    await db.execute('''
      CREATE TABLE IF NOT EXISTS $entityName (
        id TEXT PRIMARY KEY,
        version INTEGER NOT NULL DEFAULT 1,
        updated_at INTEGER NOT NULL,
        _base_snapshot_json TEXT
        $fullCols
        $fk
      );
    ''');
  }

  /// Atomically commits domain entity record and outbox mutation envelope.
  /// If outbox insert fails, the domain record write is automatically rolled back.
  Future<String> save({
    required String entity,
    required String id,
    required Map<String, dynamic> data,
    int version = 1,
    String? dependsOnMutationId,
    int schemaVersion = 1,
    String? endpointUrl,
    String? httpMethod,
  }) async {
    return await db.writeTransaction<String>((tx) async {
      // 1. Read existing row to capture shadow baseline for rollback
      final existingRows = await tx.getAll('SELECT * FROM $entity WHERE id = ?', [id]);
      String? baseSnapshotJson;
      int baseVersion = 1;

      if (existingRows.isNotEmpty) {
        final row = Map<String, dynamic>.from(existingRows.first);
        row.remove('_base_snapshot_json');
        baseSnapshotJson = jsonEncode(row);
        baseVersion = (row['version'] as int?) ?? 1;
      }

      // 2. Ensure missing columns exist dynamically in the SQLite table
      for (final key in data.keys) {
        if (key != 'id' && key != 'version' && key != 'updated_at' && key != '_base_snapshot_json') {
          try {
            await tx.execute('ALTER TABLE $entity ADD COLUMN $key TEXT');
          } catch (_) {}
        }
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      final columns = <String>['id', 'version', 'updated_at', '_base_snapshot_json'];
      final values = <dynamic>[id, version, now, baseSnapshotJson];

      for (final entry in data.entries) {
        if (entry.key != 'id' && entry.key != 'version' && entry.key != 'updated_at') {
          columns.add(entry.key);
          values.add(entry.value);
        }
      }

      final colList = columns.join(', ');
      final placeholders = columns.map((_) => '?').join(', ');

      await tx.execute(
        'INSERT OR REPLACE INTO $entity ($colList) VALUES ($placeholders)',
        values,
      );

      // 3. Append outbox mutation envelope with optional DAG dependency and schema version
      final mutationId = UuidV7.generate();
      await tx.execute('''
        INSERT INTO _sync_outbox (
          mutation_id, entity_name, entity_id, op, endpoint_url, http_method, payload_json,
          base_snapshot_json, base_version, status, depends_on_mutation_id, schema_version, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?)
      ''', [
        mutationId,
        entity,
        id,
        'upsert',
        endpointUrl,
        httpMethod,
        jsonEncode(data),
        baseSnapshotJson,
        baseVersion,
        dependsOnMutationId,
        schemaVersion,
        now,
      ]);

      return mutationId;
    });
  }

  /// Atomically marks domain entity deleted and appends delete envelope to outbox.
  Future<String> delete({
    required String entity,
    required String id,
    String? endpointUrl,
    String? httpMethod,
  }) async {
    return await db.writeTransaction<String>((tx) async {
      final existingRows = await tx.getAll('SELECT * FROM $entity WHERE id = ?', [id]);
      String? baseSnapshotJson;
      int baseVersion = 1;

      if (existingRows.isNotEmpty) {
        final row = Map<String, dynamic>.from(existingRows.first);
        row.remove('_base_snapshot_json');
        baseSnapshotJson = jsonEncode(row);
        baseVersion = (row['version'] as int?) ?? 1;
      }

      await tx.execute('DELETE FROM $entity WHERE id = ?', [id]);

      final mutationId = UuidV7.generate();
      final now = DateTime.now().millisecondsSinceEpoch;

      await tx.execute('''
        INSERT INTO _sync_outbox (
          mutation_id, entity_name, entity_id, op, endpoint_url, http_method, payload_json,
          base_snapshot_json, base_version, status, created_at
        ) VALUES (?, ?, ?, 'delete', ?, ?, NULL, ?, ?, 'pending', ?)
      ''', [
        mutationId,
        entity,
        id,
        endpointUrl,
        httpMethod ?? 'DELETE',
        baseSnapshotJson,
        baseVersion,
        now,
      ]);

      return mutationId;
    });
  }

  /// Rolls back an optimistic mutation using its stored base snapshot.
  Future<void> rollbackOptimistic(String mutationId, {String status = 'conflict'}) async {
    await db.writeTransaction((tx) async {
      final rows = await tx.getAll('SELECT * FROM _sync_outbox WHERE mutation_id = ?', [mutationId]);
      if (rows.isEmpty) return;

      final outbox = rows.first;
      final entity = outbox['entity_name'] as String;
      final id = outbox['entity_id'] as String;
      final baseJson = outbox['base_snapshot_json'] as String?;

      if (baseJson == null) {
        // Record was newly inserted optimistically; rollback by deleting it
        await tx.execute('DELETE FROM $entity WHERE id = ?', [id]);
      } else {
        // Restore pre-mutation baseline snapshot
        final baseline = jsonDecode(baseJson) as Map<String, dynamic>;
        final cols = baseline.keys.join(', ');
        final placeholders = baseline.keys.map((_) => '?').join(', ');
        await tx.execute(
          'INSERT OR REPLACE INTO $entity ($cols, _base_snapshot_json) VALUES ($placeholders, NULL)',
          [...baseline.values],
        );
      }

      await tx.execute(
        'UPDATE _sync_outbox SET status = ? WHERE mutation_id = ?',
        [status, mutationId],
      );
    });
  }

  /// Streams reactive updates on any SQL query without requiring codegen TableInfo.
  Stream<ResultSet> watch(String query, {List<dynamic> parameters = const []}) {
    return db.watch(query, parameters: parameters);
  }

  bool _closed = false;

  /// Closes database connections.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await db.close();
  }
}
