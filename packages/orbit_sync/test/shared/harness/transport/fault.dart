/// Sealed fault types for deterministic network fault injection.
sealed class Fault {
  const Fault();
}

/// Socket dropped before sending any request bytes.
class DropSocketBeforeRequest extends Fault {
  const DropSocketBeforeRequest();
}

/// Server receives bytes, but the connection is severed before headers return.
/// Simulates Two Generals Problem.
class DropSocketAfterRequestBody extends Fault {
  const DropSocketAfterRequestBody();
}

/// Canned HTTP status, body, and headers returned deterministically.
class ReturnStatus extends Fault {
  final int statusCode;
  final String? body;
  final Map<String, String>? headers;
  const ReturnStatus(this.statusCode, {this.body, this.headers});
}

/// Injects artificial latency into the transport.
class DelayResponse extends Fault {
  final Duration duration;
  const DelayResponse(this.duration);
}

/// Truncates the response stream mid-transfer.
class TruncateResponse extends Fault {
  final int bytesToSend;
  const TruncateResponse(this.bytesToSend);
}

/// Injected DNS lookup resolution failure.
class DnsFailure extends Fault {
  const DnsFailure();
}

/// Injected TLS handshake / certificate validation failure.
class TlsFailure extends Fault {
  const TlsFailure();
}
