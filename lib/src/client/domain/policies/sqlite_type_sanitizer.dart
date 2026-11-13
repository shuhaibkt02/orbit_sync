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
    if (value is int ||
        value is double ||
        value is String ||
        value is Uint8List) {
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

  /// Sanitizes a list of values (e.g. query parameters or whereArgs).
  List<dynamic> sanitizeList(List<dynamic> list) =>
      list.map(sanitizeValue).toList();

  /// Sanitizes an entire key-value map for SQLite INSERT/UPDATE execution.
  Map<String, dynamic> sanitizeMap(Map<String, dynamic> input) {
    final result = <String, dynamic>{};
    for (final entry in input.entries) {
      result[entry.key] = sanitizeValue(entry.value);
    }
    return result;
  }

  /// Safely decodes a SQLite row map back into rich Dart structures (Maps/Lists/booleans),
  /// preventing TypeErrors when user models call `fromJson`.
  Map<String, dynamic> decodeRow(Map<String, dynamic> row) {
    Map<String, dynamic> result = {};
    if (row.containsKey('data_json') && row['data_json'] is String) {
      try {
        final parsed = jsonDecode(row['data_json'] as String);
        if (parsed is Map<String, dynamic>) {
          result = Map<String, dynamic>.from(parsed);
        }
      } catch (_) {}
    }
    for (final entry in row.entries) {
      if (entry.key == 'data_json' || entry.key == '_base_snapshot_json')
        continue;
      final val = entry.value;
      if (val is String && val.isNotEmpty) {
        final first = val[0];
        if (first == '{' || first == '[') {
          try {
            result[entry.key] = jsonDecode(val);
            continue;
          } catch (_) {}
        }
      }
      if (!result.containsKey(entry.key)) {
        result[entry.key] = val;
      }
    }
    if (row.containsKey('expires_at') && row['expires_at'] != null) {
      final exp = row['expires_at'];
      if (exp is int) {
        final isStale = exp <= DateTime.now().millisecondsSinceEpoch;
        result.putIfAbsent('isStale', () => isStale);
        result.putIfAbsent('is_stale', () => isStale);
      }
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
