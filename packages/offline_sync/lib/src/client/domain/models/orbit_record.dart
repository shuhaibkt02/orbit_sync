import 'orbit_sync_status.dart';

/// Strongly-typed wrapper coupling a domain entity with its offline sync metadata.
class OrbitRecord<T> {
  final T data;
  final OrbitSyncStatus status;
  final String? errorMessage;
  final DateTime? updatedAt;
  final String? mutationId;

  const OrbitRecord({
    required this.data,
    this.status = OrbitSyncStatus.synced,
    this.errorMessage,
    this.updatedAt,
    this.mutationId,
  });

  bool get isDirty => status.isDirty;
  bool get isSynced => status == OrbitSyncStatus.synced;
  bool get isRejected => status == OrbitSyncStatus.rejected;
  bool get isPendingDelete => status == OrbitSyncStatus.pendingDelete;

  @override
  String toString() => 'OrbitRecord(status: $status, data: $data)';
}
