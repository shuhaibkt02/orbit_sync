/// Policy governing outbox dispatch over metered/cellular networks.
enum NetworkMeteredPolicy {
  /// Sync all mutations unconditionally regardless of connection type.
  any,

  /// Sync JSON mutations over cellular, but hold heavy media attachments for Wi-Fi.
  wifiOnlyMedia,

  /// Completely halt all synchronization when connected to a metered connection.
  wifiOnlyAll;

  /// Evaluates whether an outbox mutation can be dispatched given [isMetered] and [isMedia].
  bool canSync({required bool isMetered, required bool isMedia}) {
    if (!isMetered) return true;
    return switch (this) {
      NetworkMeteredPolicy.any => true,
      NetworkMeteredPolicy.wifiOnlyMedia => !isMedia,
      NetworkMeteredPolicy.wifiOnlyAll => false,
    };
  }
}
