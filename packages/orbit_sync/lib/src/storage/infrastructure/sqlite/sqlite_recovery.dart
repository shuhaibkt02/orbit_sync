import 'dart:convert';
import 'dart:io';
import 'package:sqlite_async/sqlite_async.dart';
import '../../domain/interfaces/i_storage_recovery.dart';
import '../uuid/uuid_v7.dart';

/// Concrete SQLite file corruption recovery and cloud backup integrity checker.
class SqliteRecovery implements IStorageRecovery {
  const SqliteRecovery();

  @override
  void sniffAndQuarantineIfCorrupted(
    String path,
    void Function(String corruptPath)? onDatabaseCorrupted,
  ) {
    if (path == ':memory:') return;
    final file = File(path);
    if (!file.existsSync()) return;

    bool isCorrupt = false;
    try {
      final len = file.lengthSync();
      if (len > 0 && len < 100) {
        isCorrupt = true;
      } else if (len >= 100) {
        final raf = file.openSync();
        try {
          final header = raf.readSync(16);
          final magic = utf8.decode(header.sublist(0, 15), allowMalformed: true);
          if (!magic.startsWith('SQLite format 3')) {
            isCorrupt = true;
          }
        } finally {
          raf.closeSync();
        }
      }
    } catch (_) {
      isCorrupt = true;
    }

    if (isCorrupt) {
      quarantineCorruptFiles(path, onDatabaseCorrupted);
    }
  }

  @override
  void quarantineCorruptFiles(
    String path,
    void Function(String corruptPath)? onDatabaseCorrupted,
  ) {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final corruptPath = '$path.corrupt_$ts';
    final file = File(path);
    if (file.existsSync()) {
      try {
        file.renameSync(corruptPath);
      } catch (_) {}
    }
    final walFile = File('$path-wal');
    if (walFile.existsSync()) {
      try {
        walFile.renameSync('$corruptPath-wal');
      } catch (_) {}
    }
    final shmFile = File('$path-shm');
    if (shmFile.existsSync()) {
      try {
        shmFile.renameSync('$corruptPath-shm');
      } catch (_) {}
    }
    onDatabaseCorrupted?.call(corruptPath);
  }

  @override
  Future<void> verifyInstallationIntegrity(
    SqliteDatabase db, {
    required Future<String?> Function(String key) secureStorageReader,
    required Future<void> Function(String key, String value) secureStorageWriter,
    void Function(String sqliteId, String secureId)? onTimeTravelBackupDetected,
  }) async {
    const key = 'orbit_installation_id';
    final secureId = await secureStorageReader(key);

    final rows = await db.getAll('SELECT value FROM _sync_metadata WHERE key = ?;', [key]);
    final sqliteId = rows.isNotEmpty ? rows.first['value'] as String? : null;

    if (secureId == null && sqliteId == null) {
      // First boot: create new unique installation ID for this device
      final newId = UuidV7.generate();
      await secureStorageWriter(key, newId);
      await db.execute('INSERT OR REPLACE INTO _sync_metadata (key, value) VALUES (?, ?);', [key, newId]);
    } else if (secureId != null && sqliteId == null) {
      // Fresh database on existing installation: bind to secureId
      await db.execute('INSERT OR REPLACE INTO _sync_metadata (key, value) VALUES (?, ?);', [key, secureId]);
    } else if (secureId == null && sqliteId != null) {
      // Secure storage wiped or new device with restored SQLite database
      onTimeTravelBackupDetected?.call(sqliteId, 'none');
      // Hold all pending outbox mutations from firing blindly
      await db.execute("UPDATE _sync_outbox SET status = 'held' WHERE status IN ('pending', 'in_flight');");
      final newId = UuidV7.generate();
      await secureStorageWriter(key, newId);
      await db.execute('INSERT OR REPLACE INTO _sync_metadata (key, value) VALUES (?, ?);', [key, newId]);
    } else if (secureId != sqliteId) {
      // MISMATCH: An outdated backup from another device/session was restored over this device!
      onTimeTravelBackupDetected?.call(sqliteId!, secureId!);
      // Hold all pending outbox mutations from firing blindly against modern server state
      await db.execute("UPDATE _sync_outbox SET status = 'held' WHERE status IN ('pending', 'in_flight');");
    }
  }
}
