import 'package:sqlite_async/sqlite_async.dart';

/// Inverted contract for database corruption quarantine and cloud backup verification.
abstract class IStorageRecovery {
  /// Sniffs the physical file header before opening and quarantines if corrupt.
  void sniffAndQuarantineIfCorrupted(
    String path,
    void Function(String corruptPath)? onDatabaseCorrupted,
  );

  /// Renames database and WAL/SHM files to a timestamped backup path.
  void quarantineCorruptFiles(
    String path,
    void Function(String corruptPath)? onDatabaseCorrupted,
  );

  /// Compares local SQLite metadata against platform Keychain/Keystore.
  Future<void> verifyInstallationIntegrity(
    SqliteDatabase db, {
    required Future<String?> Function(String key) secureStorageReader,
    required Future<void> Function(String key, String value)
        secureStorageWriter,
    void Function(String sqliteId, String secureId)? onTimeTravelBackupDetected,
  });
}
