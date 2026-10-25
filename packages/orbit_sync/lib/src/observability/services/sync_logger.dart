import 'dart:collection';
import '../domain/models/log_level.dart';
import '../domain/models/sync_log_entry.dart';
import '../domain/models/sync_event.dart';

/// In-memory circular buffer logger preventing user phone storage bloat (Challenge 1).
///
/// Keeps the last [capacity] (default 100) log entries in memory.
/// If an error occurs, the host app can dump logs via [dumpLogs] to Sentry or Firebase.
class SyncLogger {
  final int capacity;
  LogLevel minLevel;
  final ListQueue<SyncLogEntry> _buffer;

  SyncLogger({
    int capacity = 100,
    this.minLevel = LogLevel.warn,
  })  : capacity = capacity < 1 ? 1 : capacity,
        _buffer = ListQueue<SyncLogEntry>(capacity < 1 ? 1 : capacity);

  int get length => _buffer.length;
  bool get isEmpty => _buffer.isEmpty;
  bool get isNotEmpty => _buffer.isNotEmpty;

  void log(
    LogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (level < minLevel) return;
    final entry = SyncLogEntry(
      level: level,
      message: message,
      error: error,
      stackTrace: stackTrace,
    );
    if (_buffer.length >= capacity) {
      _buffer.removeFirst();
    }
    _buffer.addLast(entry);
  }

  void debug(String message) => log(LogLevel.debug, message);
  void info(String message) => log(LogLevel.info, message);
  void warn(String message, [Object? error]) => log(LogLevel.warn, message, error: error);
  void error(String message, [Object? error, StackTrace? stackTrace]) =>
      log(LogLevel.error, message, error: error, stackTrace: stackTrace);

  /// Automatically categorizes and logs a [SyncEvent] at appropriate severity.
  void logEvent(SyncEvent event) {
    switch (event) {
      case SlaBreachedEvent(:final entity, :final mutationId, :final age):
        error('SLA Breached: $entity/$mutationId after ${age.inMinutes}m');
      case PoisonPillQuarantinedEvent(:final entity, :final mutationId, :final reason):
        error('Poison Pill Quarantined: $entity/$mutationId - $reason');
      case CascadeFailureEvent(:final parentMutationId, :final childMutationId):
        error('Cascade Failure: Child $childMutationId held due to parent $parentMutationId');
      case SlaWarningEvent(:final entity, :final mutationId, :final age):
        warn('SLA Warning: $entity/$mutationId approaching deadline (${age.inMinutes}m)');
      case StorageWarningEvent(:final message):
        warn('Storage Warning: $message');
      case RateLimitedEvent(:final retryAfterSeconds):
        warn('Rate Limited: HTTP 429 active for ${retryAfterSeconds}s');
      case SyncRejectedEvent(:final entity, :final entityId, :final errorMessage):
        warn('Sync Rejected: $entity/$entityId - $errorMessage');
      case ConflictDetectedEvent(:final entity, :final entityId):
        warn('Conflict Detected: $entity/$entityId resolved');
      case OnlineEvent():
        info('Connectivity restored');
      case OfflineEvent():
        info('Connectivity lost');
      case ProbeTimeoutEvent(:final targetUrl, :final latencyMs):
        warn('Probe Timeout: $targetUrl after ${latencyMs}ms');
      case MutationQueuedEvent(:final entity, :final entityId):
        debug('Mutation queued: $entity/$entityId');
      case MutationCoalescedEvent(:final entity, :final entityId):
        debug('Mutation coalesced: $entity/$entityId');
      case DatabasePrunedEvent(:final prunedCount, :final pruneType):
        info('Database pruned $prunedCount $pruneType records');
      case AuthExpiredEvent():
        warn('Auth Expired: HTTP 401 received');
    }
  }

  /// Returns an immutable snapshot list of currently buffered log entries.
  List<SyncLogEntry> dumpLogs() => List<SyncLogEntry>.unmodifiable(_buffer);

  /// Clears the circular buffer.
  void clear() => _buffer.clear();
}
