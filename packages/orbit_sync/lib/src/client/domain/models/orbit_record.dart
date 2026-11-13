import 'orbit_sync_status.dart';

/// Strongly-typed wrapper coupling a domain entity with its offline sync metadata.
class OrbitRecord<T> {
  final T data;
  final T? previousData;
  final OrbitSyncStatus status;
  final String? errorMessage;
  final DateTime? updatedAt;
  final String? mutationId;
  final int? expiresAt;

  const OrbitRecord({
    required this.data,
    this.previousData,
    this.status = OrbitSyncStatus.synced,
    this.errorMessage,
    this.updatedAt,
    this.mutationId,
    this.expiresAt,
  });

  bool get isDirty => status.isDirty;
  bool get isPending => status == OrbitSyncStatus.pending || status == OrbitSyncStatus.inFlight;
  bool get isSynced => status == OrbitSyncStatus.synced;
  bool get isRejected => status == OrbitSyncStatus.rejected;
  bool get isPendingDelete => status == OrbitSyncStatus.pendingDelete;
  bool get isFailed => status == OrbitSyncStatus.failed;
  bool get hasPreviousData => previousData != null;
  bool get isStale => expiresAt != null && expiresAt! <= DateTime.now().millisecondsSinceEpoch;

  @override
  String toString() => 'OrbitRecord(status: $status, data: $data)';
}
