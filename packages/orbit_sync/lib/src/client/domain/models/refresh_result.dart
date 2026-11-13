/// Status outcome of a pull-to-refresh / fetch operation.
enum RefreshStatus {
  /// Remote changes were fetched and successfully hydrated into cache.
  success,

  /// Device was offline or network probe/request failed. No cached rows were deleted.
  offline,

  /// Server responded with an error or unrecoverable response.
  error,
}

/// Strongly-typed outcome of a table pull-to-refresh / fetch operation.
///
/// Implements the "Never Purge in the Dark" protocol:
/// When offline or server fails, existing cache rows remain 100% intact
/// and [RefreshResult.offline] is returned so the host app UI can
/// dismiss refresh spinners and show an offline notice.
class RefreshResult {
  final RefreshStatus status;
  final int count;
  final String? errorMessage;

  const RefreshResult({
    required this.status,
    this.count = 0,
    this.errorMessage,
  });

  /// Static canonical representation of an offline probe or disconnected state.
  static const RefreshResult offline = RefreshResult(status: RefreshStatus.offline);

  /// Static canonical representation of a successful empty refresh.
  static const RefreshResult success = RefreshResult(status: RefreshStatus.success);

  /// Whether the operation stopped because the device is offline or unreachable.
  bool get isOffline => status == RefreshStatus.offline;

  /// Whether the operation succeeded.
  bool get isSuccess => status == RefreshStatus.success;

  /// Whether the operation encountered a server or runtime error.
  bool get isError => status == RefreshStatus.error;

  @override
  String toString() => 'RefreshResult(status: $status, count: $count, errorMessage: $errorMessage)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RefreshResult &&
          runtimeType == other.runtimeType &&
          status == other.status &&
          count == other.count &&
          errorMessage == other.errorMessage;

  @override
  int get hashCode => status.hashCode ^ count.hashCode ^ errorMessage.hashCode;
}
