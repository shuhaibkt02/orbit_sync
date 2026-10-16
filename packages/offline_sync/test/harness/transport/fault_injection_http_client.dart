import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'fault.dart';

class CapturedRequest {
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final List<int> bodyBytes;

  const CapturedRequest({
    required this.method,
    required this.url,
    required this.headers,
    required this.bodyBytes,
  });

  String get bodyText => utf8.decode(bodyBytes);
}

/// Deterministic, scripted fault-injecting HTTP client for distributed systems testing.
class FaultInjectionHttpClient extends http.BaseClient {
  final http.Client _inner;
  final Queue<Fault> _script;
  final List<CapturedRequest> captured = [];

  FaultInjectionHttpClient({
    http.Client? inner,
    List<Fault> script = const [],
  })  : _inner = inner ?? http.Client(),
        _script = Queue.of(script);

  void enqueue(Fault fault) => _script.add(fault);
  void enqueueAll(Iterable<Fault> faults) => _script.addAll(faults);
  void clearScript() => _script.clear();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().toBytes();
    captured.add(CapturedRequest(
      method: request.method,
      url: request.url,
      headers: Map.unmodifiable(request.headers),
      bodyBytes: body,
    ));

    final fault = _script.isEmpty ? null : _script.removeFirst();

    switch (fault) {
      case null:
        return _inner.send(_rebuild(request, body));
      case DropSocketBeforeRequest():
        throw const SocketException('injected: drop before request');
      case DropSocketAfterRequestBody():
        // Forward to inner so server receives and processes the bytes, then drop the socket!
        final streamed = await _inner.send(_rebuild(request, body));
        await streamed.stream.drain();
        throw const SocketException('injected: drop after request body (Two Generals)');
      case ReturnStatus(:final statusCode, :final body, :final headers):
        return _canned(request, statusCode, body ?? '', headers ?? {});
      case DelayResponse(:final duration):
        await Future<void>.delayed(duration);
        return _inner.send(_rebuild(request, body));
      case TruncateResponse(:final bytesToSend):
        final streamed = await _inner.send(_rebuild(request, body));
        return _truncate(request, streamed, bytesToSend);
      case DnsFailure():
        throw const SocketException('injected: DNS resolution failure');
      case TlsFailure():
        throw const HandshakeException('injected: TLS handshake failure');
    }
  }

  http.BaseRequest _rebuild(http.BaseRequest original, List<int> body) {
    final copy = http.Request(original.method, original.url);
    copy.headers.addAll(original.headers);
    copy.bodyBytes = body;
    return copy;
  }

  http.StreamedResponse _canned(
    http.BaseRequest request,
    int code,
    String body,
    Map<String, String> headers,
  ) {
    final bytes = utf8.encode(body);
    final responseHeaders = Map<String, String>.from(headers);
    if (!responseHeaders.containsKey('content-type')) {
      responseHeaders['content-type'] = 'application/json';
    }
    return http.StreamedResponse(
      Stream.value(bytes),
      code,
      contentLength: bytes.length,
      headers: responseHeaders,
      request: request,
    );
  }

  http.StreamedResponse _truncate(
    http.BaseRequest request,
    http.StreamedResponse original,
    int bytesToSend,
  ) {
    final truncatedStream = original.stream.take(bytesToSend);
    return http.StreamedResponse(
      truncatedStream,
      original.statusCode,
      contentLength: bytesToSend,
      headers: original.headers,
      request: request,
    );
  }

  @override
  void close() {
    _inner.close();
  }
}
