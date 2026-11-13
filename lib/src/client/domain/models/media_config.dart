/// Modes for uploading media binary attachments (Blueprint Layer 1 & 6).
enum MediaMode {
  /// Uploads metadata and binary file in a single multipart/form-data request.
  multipart,

  /// Two-step: syncs JSON document first to acquire server ID, then streams binary file.
  twoStep,
}

/// Declarative media upload configuration for an entity collection (Blueprint Layer 1).
class MediaConfig {
  /// Whether to use [MediaMode.multipart] or [MediaMode.twoStep].
  final MediaMode mode;

  /// Custom endpoint pattern for binary uploads (e.g. '/orders/{id}/receipt').
  final String? uploadEndpoint;

  /// Form field name for the binary payload (defaults to 'file').
  final String fieldName;

  const MediaConfig({
    this.mode = MediaMode.multipart,
    this.uploadEndpoint,
    this.fieldName = 'file',
  });
}

/// Metadata descriptor representing a local binary attachment on disk (Blueprint Layer 1 & 4).
///
/// Prevents mobile memory bloat and SQLite corruption by storing file paths
/// rather than raw byte buffers in SQLite.
class OrbitAttachment {
  /// Absolute path to the file on local disk.
  final String localPath;

  /// Optional original file name.
  final String? fileName;

  /// MIME type of the file (e.g. 'image/jpeg', 'application/pdf').
  final String? mimeType;

  /// Form field name used during multipart dispatch (defaults to 'file').
  final String fieldName;

  const OrbitAttachment({
    required this.localPath,
    this.fileName,
    this.mimeType,
    this.fieldName = 'file',
  });

  /// Serializes attachment metadata into JSON for storage in `data_json`.
  Map<String, dynamic> toJson() => {
    'type': 'orbit_attachment',
    'local_path': localPath,
    if (fileName != null) 'file_name': fileName,
    if (mimeType != null) 'mime_type': mimeType,
    'field_name': fieldName,
  };

  /// Deserializes attachment metadata from JSON.
  factory OrbitAttachment.fromJson(Map<String, dynamic> json) => OrbitAttachment(
    localPath: (json['local_path'] ?? json['localPath'] ?? json['media_path'] ?? json['mediaPath'] ?? '').toString(),
    fileName: json['file_name']?.toString() ?? json['fileName']?.toString(),
    mimeType: json['mime_type']?.toString() ?? json['mimeType']?.toString(),
    fieldName: json['field_name']?.toString() ?? json['fieldName']?.toString() ?? 'file',
  );

  @override
  String toString() => 'OrbitAttachment(path: $localPath, mimeType: $mimeType)';
}
