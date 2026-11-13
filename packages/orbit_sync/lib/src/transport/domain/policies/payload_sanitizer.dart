/// Strips internal Orbit metadata and sync flags before payloads are serialized to the wire.
Map<String, dynamic> sanitizePayload(Map<String, dynamic> payload) {
  final clean = <String, dynamic>{};
  for (final entry in payload.entries) {
    if (isInternalSyncFlag(entry.key)) continue;
    clean[entry.key] = _sanitizeValue(entry.value);
  }
  return clean;
}

/// Identifies internal sync flags and metadata keys that must never leak to the backend.
bool isInternalSyncFlag(String key) {
  final lower = key.toLowerCase();
  return lower.startsWith('_sync_') ||
      lower.startsWith('_offline_') ||
      lower == 'expires_at' ||
      lower == 'updated_at' ||
      lower == '_base_snapshot_json' ||
      lower == '_base_snapshot';
}

dynamic _sanitizeValue(dynamic value) {
  if (value is Map<String, dynamic>) {
    return sanitizePayload(value);
  } else if (value is Map) {
    return sanitizePayload(Map<String, dynamic>.from(value));
  } else if (value is List) {
    return value.map(_sanitizeValue).toList();
  }
  return value;
}
