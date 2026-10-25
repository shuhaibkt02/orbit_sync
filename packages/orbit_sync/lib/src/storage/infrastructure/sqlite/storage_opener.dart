import 'dart:async';
import 'dart:io';
import 'package:sqlite_async/sqlite_async.dart';
import '../../sync_storage.dart';

/// Handles database bootstrap, recovery, quarantine, and schema initialization.
class StorageOpener {
  static Future<SyncStorage> open({
    required String path,
    int maxReaders = 4,
    void Function(String corruptPath)? onDatabaseCorrupted,
    Future<bool> Function(String path)? backupShield,
    Future<String?> Function(String key)? secureStorageReader,
    Future<void> Function(String key, String value)? secureStorageWriter,
    void Function(String sqliteId, String secureId)? onTimeTravelBackupDetected,
    IStorageRecovery recovery = const SqliteRecovery(),
  }) async {
    if (backupShield != null && path != ':memory:') {
      try { await backupShield(path); } catch (_) {}
    }

    recovery.sniffAndQuarantineIfCorrupted(path, onDatabaseCorrupted);

    const sqliteOptions = SqliteOptions(
      journalMode: SqliteJournalMode.wal,
      journalSizeLimit: 67108864, // 64 MB
      lockTimeout: Duration(seconds: 30),
    );

    SqliteDatabase db = SqliteDatabase(path: path, maxReaders: maxReaders, options: sqliteOptions);
    bool deepCorrupt = false;
    try {
      await db.initialize();
      if (path != ':memory:' && File(path).existsSync()) {
        final check = await db.get('PRAGMA quick_check(1);');
        if (check.values.first?.toString().toLowerCase() != 'ok') deepCorrupt = true;
      }
    } catch (_) {
      deepCorrupt = true;
    }

    if (deepCorrupt && path != ':memory:') {
      try { await db.close(); } catch (_) {}
      recovery.quarantineCorruptFiles(path, onDatabaseCorrupted);
      db = SqliteDatabase(path: path, maxReaders: maxReaders, options: sqliteOptions);
      await db.initialize();
    }

    await SqliteSchema.initSystemSchema(db);

    if (secureStorageReader != null && secureStorageWriter != null) {
      await recovery.verifyInstallationIntegrity(
        db,
        secureStorageReader: secureStorageReader,
        secureStorageWriter: secureStorageWriter,
        onTimeTravelBackupDetected: onTimeTravelBackupDetected,
      );
    }

    return SyncStorage.withRepositories(
      db: db,
      path: path,
      outboxRepo: SqliteOutboxRepository(db),
      idMapRepo: SqliteIdMapRepository(db),
    );
  }
}
