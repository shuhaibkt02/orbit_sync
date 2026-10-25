import 'log_level.dart';

/// Single structured diagnostic log entry captured in the in-memory circular buffer.
class SyncLogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final String message;
  final Object? error;
  final StackTrace? stackTrace;

  SyncLogEntry({
    DateTime? timestamp,
    required this.level,
    required this.message,
    this.error,
    this.stackTrace,
  }) : timestamp = timestamp ?? DateTime.now().toUtc();

  @override
  String toString() {
    final errStr = error != null ? ' | Error: $error' : '';
    return '[${level.label}] ${timestamp.toIso8601String()}: $message$errStr';
  }
}
