import 'dart:convert';
import 'dart:io';
import '../../storage/sync_storage.dart';
import '../../transport/sync_transport.dart';
import '../../sync_profile.dart';
import '../domain/models/sync_result.dart';
import 'conflict_reconciler.dart';
import 'pull_change_applier.dart';

/// Pull orchestrator managing changelog pagination and checkpoint cursors.
class PagePullOrchestrator {
  final SyncStorage storage;
  final SyncTransport transport;
  final int pullPageLimit;
  final Map<String, dynamic>? scopeFilter;
  final Future<void> Function()? onAuthExpired;
  final Future<void> Function()? onExpiredCursor;
  final PullChangeApplier _applier;

  PagePullOrchestrator({
    required this.storage,
    required this.transport,
    required SyncProfile profile,
    required ConflictReconciler reconciler,
    this.pullPageLimit = 50,
    this.scopeFilter,
    this.onAuthExpired,
    this.onExpiredCursor,
  }) : _applier = PullChangeApplier(profile: profile, reconciler: reconciler);

  /// Pulls a single page of changes and reconciles into SQLite.
  Future<SyncPullResult> pullPage({String? chaos}) async {
    final since = await getLastSyncedCursor();

    try {
      final resp = await transport.pull(
        sinceCursor: since,
        limit: pullPageLimit,
        scopeFilter: scopeFilter,
        chaos: chaos,
      );
      if (resp.error != null) {
        throw resp.error is Exception ? resp.error as Exception : Exception(resp.error.toString());
      }
      if (resp.statusCode == HttpStatus.gone) {
        return const SyncPullResult(status: SyncPullStatus.expiredCursor);
      }
      if (resp.statusCode == HttpStatus.unauthorized) {
        if (onAuthExpired != null) {
          await onAuthExpired!();
        }
        return const SyncPullResult(status: SyncPullStatus.unauthorized);
      }
      if (resp.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${resp.statusCode}: ${resp.body}');
      }

      final bodyJson = jsonDecode(resp.body) as Map<String, dynamic>;
      final changes = (bodyJson['changes'] as List).cast<Map<String, dynamic>>();
      final nextCursor = bodyJson['next_cursor'] as int;
      final hasMore = bodyJson['has_more'] as bool;

      await storage.db.writeTransaction((tx) async {
        for (final change in changes) {
          await _applier.processChange(tx, change);
        }

        // Commit checkpoint cursor
        await tx.execute(
          'INSERT OR REPLACE INTO _sync_metadata (key, value) VALUES (?, ?)',
          ['last_synced_cursor', nextCursor.toString()],
        );
      });

      return SyncPullResult(
        status: SyncPullStatus.success,
        changeCount: changes.length,
        nextCursor: nextCursor,
        hasMore: hasMore,
      );
    } catch (e) {
      return SyncPullResult(status: SyncPullStatus.networkError, errorMessage: e.toString());
    }
  }

  Future<int> getLastSyncedCursor() async {
    final rows = await storage.db.getAll(
      'SELECT value FROM _sync_metadata WHERE key = ?',
      ['last_synced_cursor'],
    );
    if (rows.isEmpty || rows.first['value'] == null) return 0;
    return int.tryParse(rows.first['value'] as String) ?? 0;
  }

  Future<void> setLastSyncedCursor(int cursor) async {
    await storage.db.execute(
      'INSERT OR REPLACE INTO _sync_metadata (key, value) VALUES (?, ?)',
      ['last_synced_cursor', cursor.toString()],
    );
  }

  Future<int> pullAll() async {
    int totalChanges = 0;
    while (true) {
      final res = await pullPage();
      if (res.status == SyncPullStatus.expiredCursor) {
        if (onExpiredCursor != null) {
          await onExpiredCursor!();
        }
        break;
      }
      if (res.status != SyncPullStatus.success) break;
      totalChanges += res.changeCount;
      if (!res.hasMore) break;
    }
    return totalChanges;
  }
}
