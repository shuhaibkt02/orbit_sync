/// Severity levels for Orbit in-memory logging and telemetry filtering.
enum LogLevel implements Comparable<LogLevel> {
  debug(0, 'DEBUG'),
  info(1, 'INFO'),
  warn(2, 'WARN'),
  error(3, 'ERROR'),
  none(4, 'NONE');

  final int severity;
  final String label;

  const LogLevel(this.severity, this.label);

  @override
  int compareTo(LogLevel other) => severity.compareTo(other.severity);

  bool operator >=(LogLevel other) => severity >= other.severity;
  bool operator <=(LogLevel other) => severity <= other.severity;
  bool operator >(LogLevel other) => severity > other.severity;
  bool operator <(LogLevel other) => severity < other.severity;
}
