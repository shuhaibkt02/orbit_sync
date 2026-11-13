import '../models/probe_result.dart';

/// Strategy contract for executing active network reachability probes.
abstract interface class INetworkProbe {
  /// Probes the specified [targetUri] within [timeout].
  Future<ProbeResult> probe(Uri targetUri, {Duration? timeout});

  /// Releases network sockets and HTTP clients.
  void dispose();
}
