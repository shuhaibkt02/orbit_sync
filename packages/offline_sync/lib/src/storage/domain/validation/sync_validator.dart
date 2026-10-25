import 'dart:convert';

/// Rigorous validation engine enforcing domain boundaries, types, and injection defense.
class SyncValidator {
  static final _entityRegex = RegExp(r'^[a-zA-Z0-9_]{1,64}$');

  static void validateEntity(String entity) {
    if (entity.isEmpty || !_entityRegex.hasMatch(entity)) {
      throw ArgumentError(
        'Invalid entity name "$entity". Entity names must be alphanumeric with underscores (1-64 characters).',
      );
    }
  }

  static void validateId(String id) {
    if (id.trim().isEmpty) {
      throw ArgumentError('Entity ID cannot be empty or whitespace.');
    }
    if (id.length > 256) {
      throw ArgumentError('Entity ID exceeds maximum length of 256 characters.');
    }
    if (id.contains('\x00')) {
      throw ArgumentError('Entity ID cannot contain null bytes.');
    }
  }

  static void validateVersion(int version) {
    if (version < 1) {
      throw ArgumentError('Version must be an integer >= 1. Got: $version');
    }
  }

  static void validatePriority(int priority) {
    if (priority < 0 || priority > 2) {
      throw ArgumentError('Priority must be 0 (Normal), 1 (High), or 2 (Urgent). Got: $priority');
    }
  }

  static void validateDuration(Duration? duration, String paramName) {
    if (duration != null && duration.isNegative) {
      throw ArgumentError('$paramName cannot be negative. Got: $duration');
    }
  }

  static void validateHttpMethod(String? method) {
    if (method != null) {
      const allowed = {'GET', 'POST', 'PUT', 'PATCH', 'DELETE'};
      if (!allowed.contains(method.toUpperCase())) {
        throw ArgumentError('Invalid HTTP method: "$method". Allowed: $allowed');
      }
    }
  }

  static void validateStatus(String status) {
    const allowed = {'pending', 'in_flight', 'synced', 'failed', 'dlq', 'held', 'conflict'};
    if (!allowed.contains(status)) {
      throw ArgumentError('Invalid status: "$status". Allowed: $allowed');
    }
  }

  static String encodePayload(Map<String, dynamic> data) {
    try {
      return jsonEncode(data);
    } catch (e) {
      throw ArgumentError('Invalid domain data: payload must be JSON-serializable. Error: $e');
    }
  }
}
