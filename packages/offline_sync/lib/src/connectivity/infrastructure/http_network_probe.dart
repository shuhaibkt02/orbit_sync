import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../domain/interfaces/i_network_probe.dart';
import '../domain/models/probe_result.dart';

/// Pure Dart network probe verifying end-to-end HTTP reachability,
/// gateway status codes, and captive portal redirections.
class HttpNetworkProbe implements INetworkProbe {
  final http.Client _client;
  final Duration defaultTimeout;

  HttpNetworkProbe({
    http.Client? client,
    this.defaultTimeout = const Duration(seconds: 3),
  }) : _client = client ?? http.Client();

  @override
  Future<ProbeResult> probe(Uri targetUri, {Duration? timeout}) async {
    final effectiveTimeout = timeout ?? defaultTimeout;
    final stopwatch = Stopwatch()..start();

    try {
      final request = http.Request('GET', targetUri)..followRedirects = false;
      final streamedResponse =
          await _client.send(request).timeout(effectiveTimeout);
      final statusCode = streamedResponse.statusCode;
      stopwatch.stop();

      // Drain response stream to release underlying HTTP socket / file descriptor
      unawaited(streamedResponse.stream.drain<void>().catchError((_) {}));

      // 1. Captive Portal 3xx Redirect Interception
      if (statusCode >= 300 && statusCode < 400) {
        final location = streamedResponse.headers['location'];
        final redirectUri = location != null ? Uri.tryParse(location) : null;
        final isExternalHost = redirectUri != null &&
            redirectUri.host.isNotEmpty &&
            redirectUri.host != targetUri.host;
        final isCanaryRedirect = targetUri.path.contains('generate_204');

        if (isExternalHost || isCanaryRedirect) {
          return ProbeResult.captivePortal(
            statusCode: statusCode,
            redirectUrl: redirectUri,
            latencyMs: stopwatch.elapsedMilliseconds,
          );
        }
      }

      // 2. The Gateway 401/403/404 Reachability Rule:
      // Direct responses from the configured gateway physically prove DNS and TLS work.
      if (statusCode == 200 ||
          statusCode == 204 ||
          statusCode == 401 ||
          statusCode == 403 ||
          statusCode == 404 ||
          (statusCode >= 500 && statusCode < 600)) {
        return ProbeResult.online(
          statusCode: statusCode,
          latencyMs: stopwatch.elapsedMilliseconds,
        );
      }

      return ProbeResult.unreachable(
        errorMessage: 'Unexpected HTTP status $statusCode from target probe',
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    } on SocketException catch (e) {
      return ProbeResult.unreachable(
        errorMessage: e.message,
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    } on HandshakeException catch (e) {
      // Captive portal proxy SSL interception
      return ProbeResult.captivePortal(
        errorMessage: e.message,
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    } on TimeoutException {
      return ProbeResult.unreachable(
        errorMessage: 'Probe timed out after ${effectiveTimeout.inSeconds}s',
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    } catch (e) {
      return ProbeResult.unreachable(
        errorMessage: e.toString(),
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    }
  }

  @override
  void dispose() {
    _client.close();
  }
}
