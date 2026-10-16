library offline_sync_annotation;

/// Annotation to declare a domain model as synchronized by offline_sync.
class SyncEntity {
  /// REST/HTTP endpoint (e.g. '/tasks' or '/api/v1/orders').
  final String endpoint;

  /// Custom table name. If omitted, defaults to snake_case plural of class name.
  final String? tableName;

  /// Sync profile tier: 'basic', 'standard', or 'enterprise'.
  final String profile;

  const SyncEntity({
    required this.endpoint,
    this.tableName,
    this.profile = 'standard',
  });
}

/// Marks a field as the primary key (must be a String UUIDv7).
class PrimaryKey {
  const PrimaryKey();
}

/// Optional custom field metadata.
class SyncField {
  /// Custom column name in SQLite table.
  final String? name;

  /// Set to true to exclude this field from offline storage and sync.
  final bool isIgnored;

  const SyncField({
    this.name,
    this.isIgnored = false,
  });
}
