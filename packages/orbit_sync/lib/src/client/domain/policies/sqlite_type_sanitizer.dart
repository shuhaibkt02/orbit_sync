import 'dart:convert';
import 'dart:typed_data';

/// Sanitizes Dart objects into SQLite-compatible storage primitives.
///
/// Prevents fatal SQLite C-driver `ArgumentError` crashes when developers
/// pass nested JSON maps, arrays, booleans, or DateTime instances.
class SqliteTypeSanitizer {
  const SqliteTypeSanitizer();

  /// Converts a single Dart value into a native SQLite primitive.
  dynamic sanitizeValue(dynamic value) {
    if (value == null) return null;
    if (value is int || value is double || value is String || value is Uint8List) {
      return value;
    }
    if (value is bool) {
      return value ? 1 : 0;
    }
    if (value is DateTime) {
      return value.millisecondsSinceEpoch;
    }
    if (value is Map || value is List) {
      return jsonEncode(value);
    }
    return value.toString();
  }

  /// Sanitizes an entire key-value map for SQLite INSERT/UPDATE execution.
  Map<String, dynamic> sanitizeMap(Map<String, dynamic> input) {
    final result = <String, dynamic>{};
    for (final entry in input.entries) {
      result[entry.key] = sanitizeValue(entry.value);
    }
    return result;
  }

  /// Infers SQLite storage type for a given Dart runtime value.
  String inferColumnType(dynamic value) {
    if (value is int || value is bool || value is DateTime) return 'INTEGER';
    if (value is double) return 'REAL';
    if (value is Uint8List) return 'BLOB';
    return 'TEXT';
  }
}
