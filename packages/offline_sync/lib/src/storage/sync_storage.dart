import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:sqlite3/sqlite3.dart' show ResultSet;
import 'package:sqlite_async/sqlite_async.dart';
import 'uuid_v7.dart';
import 'sync_validator.dart';
import 'storage_recovery.dart';

export 'sync_validator.dart';
export 'storage_recovery.dart';

/// Manages local SQLite storage with WAL mode, dedicated writer isolate,
/// transactional outbox, shadow-base materialization, and reactive streams.
class SyncStorage {
  final SqliteDatabase db;
  final String path;
  final Set<String> _knownColumns = <String>{};

  static const _systemEntityCols = {
    'id',
    'version',
    'updated_at',
    'expires_at',
    '_base_snapshot_json',
    'data_json',
  };

  SyncStorage._(this.db, this.path);

  /// Opens or creates database at [path] with connection pooling.
  /// If disk image corruption is detected (e.g. abrupt power failure),
  /// quarantines the corrupted files to [path].corrupt_<timestamp> and opens a clean database.
  ///
  /// Supports [backupShield] to flag database files as excluded from cloud backup,
  /// and [secureStorageReader]/[secureStorageWriter] to verify installation IDs and protect
  /// against the Cloud Backup Time-Travel bug (Section 5.7).
  static Future<SyncStorage> open({
    required String path,
    int maxReaders = 4,
    void Function(String corruptPath)? onDatabaseCorrupted,
    Future<bool> Function(String path)? backupShield,
    Future<String?> Function(String key)? secureStorageReader,
    Future<void> Function(String key, String value)? secureStorageWriter,
    void Function(String sqliteId, String secureId)? onTimeTravelBackupDetected,
  }) async {
    // 1. Invoke host platform backup exclusion shield if provided
    if (backupShield != null && path != ':memory:') {
      try {
        await backupShield(path);
      } catch (_) {}
    }

    // 2. Proactive header check for pre-existing disk files before isolate spawn
    StorageRecovery.sniffAndQuarantineIfCorrupted(path, onDatabaseCorrupted);

    const sqliteOptions = SqliteOptions(
      journalMode: SqliteJournalMode.wal,
      journalSizeLimit: 67108864, // 64 MB
      lockTimeout: Duration(seconds: 30),
    );

    SqliteDatabase db = SqliteDatabase(
      path: path,
      maxReaders: maxReaders,
      options: sqliteOptions,
    );

    bool deepCorrupt = false;
    try {
      await db.initialize();
      if (path != ':memory:' && File(path).existsSync()) {
        final check = await db.get('PRAGMA quick_check(1);');
        final status = check.values.first?.toString().toLowerCase();
        if (status != 'ok') {
          deepCorrupt = true;
        }
      }
    } catch (_) {
      deepCorrupt = true;
    }

    if (deepCorrupt && path != ':memory:') {
      try {
        await db.close();
      } catch (_) {}
      StorageRecovery.quarantineCorruptFiles(path, onDatabaseCorrupted);

      db = SqliteDatabase(
        path: path,
        maxReaders: maxReaders,
        options: sqliteOptions,
      );
      await db.initialize();
    }

    final storage = SyncStorage._(db, path);
    await storage._initSystemSchema();

    // 3. Verify installation integrity against cloud backup time-travel bugs
    if (secureStorageReader != null && secureStorageWriter != null) {
      await StorageRecovery.verifyInstallationIntegrity(
        db,
        secureStorageReader: secureStorageReader,
        secureStorageWriter: secureStorageWriter,
        onTimeTravelBackupDetected: onTimeTravelBackupDetected,
      );
    }

    return storage;
  }

  /// Initializes system tables: _sync_outbox, _sync_id_map, and _sync_metadata
  Future<void> _initSystemSchema() async {
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

      // 2. Startup recovery: Reset any stranded in_flight records from interrupted sessions
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
  Future<void> registerEntityTable(
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

    _knownColumns.addAll([
      '$entityName:id',
      '$entityName:version',
      '$entityName:updated_at',
      '$entityName:expires_at',
      '$entityName:_base_snapshot_json',
      '$entityName:data_json',
    ]);
    for (final col in columnTypes.keys) {
      _knownColumns.add('$entityName:$col');
    }
  }

  /// Atomically commits domain entity record and outbox mutation envelope.
  /// Validates all static system fields strictly, while storing clean user data directly in data_json.
  Future<String> save({
    required String entity,
    required String id,
    required Map<String, dynamic> data,
    int version = 1,
    String? dependsOnMutationId,
    int schemaVersion = 1,
    String? endpointUrl,
    String? httpMethod,
    Duration? holdFor,
    Duration? sla,
    Duration? ttl,
    int priority = 0,
    String? correlationTag,
  }) async {
    // 1. Strict validation of all static system parameters
    SyncValidator.validateEntity(entity);
    SyncValidator.validateId(id);
    SyncValidator.validateVersion(version);
    SyncValidator.validatePriority(priority);
    SyncValidator.validateDuration(holdFor, 'holdFor');
    SyncValidator.validateDuration(sla, 'sla');
    SyncValidator.validateDuration(ttl, 'ttl');
    SyncValidator.validateHttpMethod(httpMethod);

    // 2. Validate user payload serialization without touching business fields
    final cleanPayloadJson = SyncValidator.encodePayload(data);

    return await db.writeTransaction<String>((tx) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final dispatchAfter = holdFor != null ? now + holdFor.inMilliseconds : now;
      final slaSeconds = sla?.inSeconds ?? 86400;
      final expiresAt = ttl != null ? now + ttl.inMilliseconds : null;

      // 3. Ensure domain table exists with static container schema & TTL support
      if (!_knownColumns.contains('$entity:id')) {
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
        _knownColumns.addAll([
          '$entity:id',
          '$entity:version',
          '$entity:updated_at',
          '$entity:expires_at',
          '$entity:_base_snapshot_json',
          '$entity:data_json',
        ]);
      }

      // 4. Read existing row to capture shadow baseline for rollback & conflict handling
      final baseline = await _readExistingBaseline(tx, entity, id);
      final baseSnapshotJson = baseline.snapshot;
      final baseVersion = baseline.version;

      // 5. Ensure missing columns exist dynamically in the SQLite table with proper type affinity
      for (final entry in data.entries) {
        final key = entry.key;
        if (!_systemEntityCols.contains(key)) {
          if (_knownColumns.contains('$entity:$key')) continue;
          try {
            final val = entry.value;
            final String colType = val is int
                ? 'INTEGER'
                : val is double
                    ? 'REAL'
                    : val is bool
                        ? 'INTEGER'
                        : (val is Uint8List)
                            ? 'BLOB'
                            : 'TEXT';
            await tx.execute('ALTER TABLE "$entity" ADD COLUMN "$key" $colType');
          } catch (_) {}
          _knownColumns.add('$entity:$key');
        }
      }

      final columns = <String>['id', 'version', 'updated_at', 'expires_at', '_base_snapshot_json', 'data_json'];
      final values = <dynamic>[id, version, now, expiresAt, baseSnapshotJson, cleanPayloadJson];

      for (final entry in data.entries) {
        if (!_systemEntityCols.contains(entry.key)) {
          columns.add(entry.key);
          final val = entry.value;
          if (val is bool) {
            values.add(val ? 1 : 0);
          } else if (val is Map || (val is List && val is! Uint8List)) {
            values.add(jsonEncode(val));
          } else {
            values.add(val);
          }
        }
      }

      final colList = columns.map((c) => '"$c"').join(', ');
      final placeholders = columns.map((_) => '?').join(', ');

      await tx.execute(
        'INSERT OR REPLACE INTO "$entity" ($colList) VALUES ($placeholders)',
        values,
      );

      // 6. Grace Window Check: Coalesce if an active mutation is within its hold window
      final pendingMutations = await tx.getAll(
        "SELECT mutation_id, payload_json, revision_history_json FROM _sync_outbox WHERE entity_name = ? AND entity_id = ? AND status = 'pending' AND dispatch_after > ? ORDER BY sequence_id DESC LIMIT 1",
        [entity, id, now],
      );

      if (pendingMutations.isNotEmpty) {
        final existing = pendingMutations.first;
        final existingMutationId = existing['mutation_id'] as String;
        final oldPayload = existing['payload_json'] as String?;
        final oldHistoryJson = existing['revision_history_json'] as String?;

        List<dynamic> history = [];
        if (oldHistoryJson != null && oldHistoryJson.isNotEmpty) {
          try {
            history = jsonDecode(oldHistoryJson) as List<dynamic>;
          } catch (_) {}
        }

        if (oldPayload != null) {
          history.add({
            'timestamp': now,
            'snapshot': jsonDecode(oldPayload),
          });
        }

        await tx.execute('''
          UPDATE _sync_outbox
          SET payload_json = ?,
              revision_history_json = ?,
              updated_at = ?
          WHERE mutation_id = ?
        ''', [
          cleanPayloadJson,
          jsonEncode(history),
          now,
          existingMutationId,
        ]);

        return existingMutationId;
      }

      // 7. Enqueue standard outbox mutation envelope
      final mutationId = UuidV7.generate();

      await tx.execute('''
        INSERT INTO _sync_outbox (
          mutation_id,
          entity_name,
          entity_id,
          op,
          endpoint_url,
          http_method,
          payload_json,
          base_snapshot_json,
          base_version,
          depends_on_mutation_id,
          correlation_tag,
          priority,
          sla_seconds,
          schema_version,
          dispatch_after,
          created_at,
          updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''', [
        mutationId,
        entity,
        id,
        baseSnapshotJson == null ? 'create' : 'update',
        endpointUrl,
        httpMethod ?? (baseSnapshotJson == null ? 'POST' : 'PUT'),
        cleanPayloadJson,
        baseSnapshotJson,
        baseVersion,
        dependsOnMutationId,
        correlationTag,
        priority,
        slaSeconds,
        schemaVersion,
        dispatchAfter,
        now,
        now,
      ]);

      return mutationId;
    });
  }

  /// Atomically marks domain entity deleted and appends delete envelope to outbox.
  /// If an unsynced creation is deleted within its grace window, both rows are annihilated locally (0 network requests).
  Future<String?> delete({
    required String entity,
    required String id,
    String? endpointUrl,
    String? httpMethod,
    Duration? undoWindow,
  }) async {
    SyncValidator.validateEntity(entity);
    SyncValidator.validateId(id);
    SyncValidator.validateDuration(undoWindow, 'undoWindow');
    SyncValidator.validateHttpMethod(httpMethod);

    return await db.writeTransaction<String?>((tx) async {
      final now = DateTime.now().millisecondsSinceEpoch;

      final tableExists = _knownColumns.contains('$entity:id') || (await tx.getAll(
        'SELECT 1 FROM sqlite_master WHERE type="table" AND name = ?',
        [entity],
      )).isNotEmpty;
      if (tableExists) {
        _knownColumns.add('$entity:id');
      }

      // 1. Grace Window Annihilation: Check if an unsynced creation is still in hold window
      final pendingCreation = await tx.getAll(
        "SELECT mutation_id FROM _sync_outbox WHERE entity_name = ? AND entity_id = ? AND status = 'pending' AND dispatch_after > ? AND base_snapshot_json IS NULL",
        [entity, id, now],
      );

      if (pendingCreation.isNotEmpty) {
        // Zero-Network Local Annihilation: Delete local domain row and purge pending outbox mutation
        if (tableExists) {
          await tx.execute('DELETE FROM "$entity" WHERE "id" = ?', [id]);
        }
        await tx.execute(
          "DELETE FROM _sync_outbox WHERE entity_name = ? AND entity_id = ? AND status = 'pending'",
          [entity, id],
        );
        return null;
      }

      // 2. Standard or Undoable Delete
      String? baseSnapshotJson;
      int baseVersion = 1;

      if (tableExists) {
        final baseline = await _readExistingBaseline(tx, entity, id);
        baseSnapshotJson = baseline.snapshot;
        baseVersion = baseline.version;
      }

      // 3. Foreign Key Cascade Capture: Find child tables that reference $entity and stage delete mutations
      final dispatchAfter = undoWindow != null ? now + undoWindow.inMilliseconds : now;
      if (tableExists) {
        try {
          final tables = await tx.getAll(
            'SELECT name FROM sqlite_master WHERE type="table" AND name NOT LIKE "\\_%" ESCAPE "\\" AND name NOT LIKE "sqlite_%";',
          );
          for (final t in tables) {
            final childTable = t['name'] as String;
            if (childTable == entity) continue;
            final fks = await tx.getAll('PRAGMA foreign_key_list("$childTable");');
            for (final fk in fks) {
              if (fk['table'] == entity) {
                final childFkCol = fk['from'] as String;
                final childRows = await tx.getAll(
                  'SELECT id, data_json, _base_snapshot_json FROM "$childTable" WHERE "$childFkCol" = ?;',
                  [id],
                );
                for (final child in childRows) {
                  final childId = child['id'] as String;
                  final childMutationId = UuidV7.generate();
                  final childBase = (child['data_json'] as String?) ?? (child['_base_snapshot_json'] as String?);
                  await tx.execute('''
                    INSERT INTO _sync_outbox (
                      mutation_id, entity_name, entity_id, op, endpoint_url, http_method, payload_json,
                      base_snapshot_json, base_version, status, dispatch_after, created_at, updated_at
                    ) VALUES (?, ?, ?, 'delete', NULL, 'DELETE', NULL, ?, 1, 'pending', ?, ?, ?)
                  ''', [
                    childMutationId,
                    childTable,
                    childId,
                    childBase,
                    dispatchAfter,
                    now,
                    now,
                  ]);
                }
              }
            }
          }
        } catch (_) {}

        await tx.execute('DELETE FROM "$entity" WHERE "id" = ?', [id]);
      }

      final mutationId = UuidV7.generate();

      await tx.execute('''
        INSERT INTO _sync_outbox (
          mutation_id, entity_name, entity_id, op, endpoint_url, http_method, payload_json,
          base_snapshot_json, base_version, status, dispatch_after, created_at, updated_at
        ) VALUES (?, ?, ?, 'delete', ?, ?, NULL, ?, ?, 'pending', ?, ?, ?)
      ''', [
        mutationId,
        entity,
        id,
        endpointUrl,
        httpMethod ?? 'DELETE',
        baseSnapshotJson,
        baseVersion,
        dispatchAfter,
        now,
        now,
      ]);

      return mutationId;
    });
  }

  /// Reads existing row baseline snapshot and version for rollback and shadow tracking.
  Future<({String? snapshot, int version})> _readExistingBaseline(
    SqliteWriteContext tx,
    String entity,
    String id,
  ) async {
    final existingRows = await tx.getAll('SELECT * FROM "$entity" WHERE "id" = ?', [id]);
    if (existingRows.isEmpty) {
      return (snapshot: null, version: 1);
    }
    final row = existingRows.first;
    var baseSnapshotJson = (row['data_json'] as String?) ?? (row['_base_snapshot_json'] as String?);
    if (baseSnapshotJson == null || baseSnapshotJson == '{}') {
      final rowMap = Map<String, dynamic>.from(row);
      rowMap.remove('_base_snapshot_json');
      rowMap.remove('data_json');
      baseSnapshotJson = jsonEncode(rowMap);
    }
    final baseVersion = (row['version'] as int?) ?? 1;
    return (snapshot: baseSnapshotJson, version: baseVersion);
  }

  /// Restores a deleted record locally if within its undoWindow.
  Future<bool> undoDelete({required String entity, required String id}) async {
    SyncValidator.validateEntity(entity);
    SyncValidator.validateId(id);

    return await db.writeTransaction<bool>((tx) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final pendingDeletes = await tx.getAll(
        "SELECT mutation_id, base_snapshot_json FROM _sync_outbox WHERE entity_name = ? AND entity_id = ? AND op = 'delete' AND status = 'pending' AND dispatch_after > ?",
        [entity, id, now],
      );

      if (pendingDeletes.isEmpty) return false;

      final mutation = pendingDeletes.first;
      final mutationId = mutation['mutation_id'] as String;
      final baseJson = mutation['base_snapshot_json'] as String?;

      if (baseJson != null) {
        await _restoreBaselineRecord(tx, entity: entity, id: id, baseJson: baseJson);
      }

      await tx.execute('DELETE FROM _sync_outbox WHERE mutation_id = ?', [mutationId]);
      return true;
    });
  }

  /// Records a local temporary ID to canonical server ID mapping.
  Future<void> registerServerId({
    required String entity,
    required String localTempId,
    required String canonicalServerId,
  }) async {
    SyncValidator.validateEntity(entity);
    SyncValidator.validateId(localTempId);
    SyncValidator.validateId(canonicalServerId);

    final now = DateTime.now().millisecondsSinceEpoch;
    await db.execute('''
      INSERT OR REPLACE INTO _sync_id_map (entity_name, local_temp_id, canonical_server_id, created_at)
      VALUES (?, ?, ?, ?)
    ''', [entity, localTempId, canonicalServerId, now]);
  }

  /// Resolves the canonical server ID for a local temporary ID.
  Future<String?> getCanonicalServerId({
    required String entity,
    required String localTempId,
  }) async {
    SyncValidator.validateEntity(entity);
    SyncValidator.validateId(localTempId);

    final rows = await db.getAll(
      'SELECT canonical_server_id FROM _sync_id_map WHERE entity_name = ? AND local_temp_id = ?',
      [entity, localTempId],
    );
    return rows.isNotEmpty ? rows.first['canonical_server_id'] as String? : null;
  }

  /// Resolves the local temporary ID for a canonical server ID.
  Future<String?> getLocalTempId({
    required String entity,
    required String canonicalServerId,
  }) async {
    SyncValidator.validateEntity(entity);
    SyncValidator.validateId(canonicalServerId);

    final rows = await db.getAll(
      'SELECT local_temp_id FROM _sync_id_map WHERE entity_name = ? AND canonical_server_id = ?',
      [entity, canonicalServerId],
    );
    return rows.isNotEmpty ? rows.first['local_temp_id'] as String? : null;
  }

  /// Prunes completed synced outbox records older than [olderThan].
  Future<int> pruneSynced({Duration olderThan = const Duration(days: 7)}) async {
    final cutoff = DateTime.now().subtract(olderThan).millisecondsSinceEpoch;
    return await db.writeTransaction<int>((tx) async {
      await tx.execute(
        "DELETE FROM _sync_outbox WHERE status = 'synced' AND updated_at < ?",
        [cutoff],
      );
      final countRow = await tx.get('SELECT changes() as count;');
      return (countRow['count'] as int?) ?? 0;
    });
  }

  /// Prunes expired local domain cache records where `expires_at < now`.
  /// Shielding: Protects dirty records that have active outbox mutations from being wiped.
  Future<int> pruneExpiredCache(String entity) async {
    SyncValidator.validateEntity(entity);

    final now = DateTime.now().millisecondsSinceEpoch;
    return await db.writeTransaction<int>((tx) async {
      final tableExists = _knownColumns.contains('$entity:id') || (await tx.getAll(
        'SELECT 1 FROM sqlite_master WHERE type="table" AND name = ?',
        [entity],
      )).isNotEmpty;
      if (!tableExists) return 0;
      _knownColumns.add('$entity:id');

      await tx.execute('''
        DELETE FROM "$entity" 
        WHERE expires_at IS NOT NULL 
          AND expires_at < ?
          AND id NOT IN (
            SELECT entity_id FROM _sync_outbox 
            WHERE entity_name = ? AND status IN ('pending', 'in_flight', 'held')
          );
      ''', [now, entity]);

      final countRow = await tx.get('SELECT changes() as count;');
      return (countRow['count'] as int?) ?? 0;
    });
  }

  /// Rolls back an optimistic mutation using its stored base snapshot.
  Future<void> rollbackOptimistic(String mutationId, {String status = 'conflict'}) async {
    SyncValidator.validateStatus(status);

    await db.writeTransaction((tx) async {
      final rows = await tx.getAll('SELECT * FROM _sync_outbox WHERE mutation_id = ?', [mutationId]);
      if (rows.isEmpty) return;

      final outbox = rows.first;
      final entity = outbox['entity_name'] as String;
      final id = outbox['entity_id'] as String;
      final baseJson = outbox['base_snapshot_json'] as String?;

      if (baseJson == null) {
        // Record was newly inserted optimistically; rollback by deleting it
        await tx.execute('DELETE FROM "$entity" WHERE "id" = ?', [id]);
      } else {
        // Restore pre-mutation baseline snapshot into domain table
        await _restoreBaselineRecord(tx, entity: entity, id: id, baseJson: baseJson);
      }

      await tx.execute(
        'UPDATE _sync_outbox SET status = ?, updated_at = ? WHERE mutation_id = ?',
        [status, DateTime.now().millisecondsSinceEpoch, mutationId],
      );
    });
  }

  /// Executes an asynchronous query against SQLite and returns the result set.
  Future<ResultSet> query(String query, [List<dynamic> parameters = const []]) {
    return db.getAll(query, parameters);
  }

  /// Streams reactive updates on any SQL query without requiring codegen TableInfo.
  Stream<ResultSet> watch(String query, {List<dynamic> parameters = const []}) {
    return db.watch(query, parameters: parameters);
  }

  /// Triggers a WAL checkpoint. If [truncate] is true, shrinks WAL file to 0 bytes.
  Future<void> checkpoint({bool truncate = false}) async {
    final mode = truncate ? 'TRUNCATE' : 'PASSIVE';
    await db.execute('PRAGMA wal_checkpoint($mode);');
  }

  /// Slices [items] into safe chunks below SQLite's variable limit (default 250)
  /// and runs [action] for each chunk, preventing SQLITE_MAX_VARIABLE_NUMBER crashes.
  static Future<void> batchChunked<T>(
    List<T> items, {
    int chunkSize = 250,
    required Future<void> Function(List<T> chunk) action,
  }) async {
    for (var i = 0; i < items.length; i += chunkSize) {
      final end = (i + chunkSize < items.length) ? i + chunkSize : items.length;
      await action(items.sublist(i, end));
    }
  }

  /// Restores a pre-mutation baseline record into its domain table.
  static Future<void> _restoreBaselineRecord(
    SqliteWriteContext tx, {
    required String entity,
    required String id,
    required String baseJson,
  }) async {
    final baseline = jsonDecode(baseJson) as Map<String, dynamic>;
    final cols = <String>['id', 'version', 'updated_at', '_base_snapshot_json', 'data_json'];
    final vals = <dynamic>[id, 1, DateTime.now().millisecondsSinceEpoch, null, baseJson];

    for (final entry in baseline.entries) {
      if (!cols.contains(entry.key)) {
        cols.add(entry.key);
        final v = entry.value;
        if (v is bool) {
          vals.add(v ? 1 : 0);
        } else if (v is Map || (v is List && v is! Uint8List)) {
          vals.add(jsonEncode(v));
        } else {
          vals.add(v);
        }
      }
    }

    final colList = cols.map((c) => '"$c"').join(', ');
    final placeholders = cols.map((_) => '?').join(', ');
    await tx.execute(
      'INSERT OR REPLACE INTO "$entity" ($colList) VALUES ($placeholders)',
      vals,
    );
  }

  bool _closed = false;

  /// Closes database connections.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await db.close();
  }
}
