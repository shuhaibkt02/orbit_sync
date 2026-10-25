import 'sync_summary.dart';

/// Sealed telemetry event emitted during synchronization operations.
sealed class OrbitSyncEvent {
  final String syncId;
  final DateTime timestamp;

  const OrbitSyncEvent({
    required this.syncId,
    required this.timestamp,
  });
}

/// Emitted immediately when a synchronization job commences.
class SyncStarted extends OrbitSyncEvent {
  final String trigger;

  const SyncStarted({
    required super.syncId,
    required super.timestamp,
    this.trigger = 'manual',
  });
}

/// Emitted periodically as records are processed (throttled to <= 100ms intervals).
class SyncProgress extends OrbitSyncEvent {
  final double progressPercentage;
  final int appliedCount;
  final int totalCount;

  const SyncProgress({
    required super.syncId,
    required super.timestamp,
    required this.progressPercentage,
    required this.appliedCount,
    required this.totalCount,
  });
}

/// Emitted upon successful or partial completion of a synchronization job.
class SyncFinished extends OrbitSyncEvent {
  final SyncSummary summary;

  const SyncFinished({
    required super.syncId,
    required super.timestamp,
    required this.summary,
  });
}

/// Emitted when a synchronization job encounters an unhandled or fatal error.
class SyncFailed extends OrbitSyncEvent {
  final String errorMessage;
  final int? statusCode;

  const SyncFailed({
    required super.syncId,
    required super.timestamp,
    required this.errorMessage,
    this.statusCode,
  });
}
