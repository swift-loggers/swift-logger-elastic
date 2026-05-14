import Foundation

/// Observable diagnostic signal emitted by the best-effort
/// ``ElasticLogger`` path. Hosts opt into observation by passing
/// an `onDiagnostic` callback to ``ElasticLogger/init(endpoint:serviceName:minimumLevel:urlSession:encoder:redactor:onDiagnostic:)``.
///
/// The callback is fired synchronously on the producer thread that
/// triggered the signal (the thread calling
/// ``ElasticLogger/log(_:_:_:attributes:)`` for
/// ``encodingFailed(_:)`` / ``bufferOverflow``). Hosts that want to
/// route diagnostics elsewhere — log them via another `Logger`,
/// surface them as metrics, etc. — SHOULD do so without blocking
/// inside the callback; the callback runs on the host's logging
/// hot path.
///
/// `ElasticLogger.log` itself remains synchronous and infallible
/// regardless of which signals fire.
public enum ElasticLoggerDiagnostic: Sendable {
    /// The configured ``ElasticDocumentEncoder`` threw on a
    /// redacted record. The entry is dropped silently after this
    /// signal fires; the logger continues processing later
    /// entries. The associated value is the encoder's error,
    /// forwarded verbatim.
    case encodingFailed(any Error)

    /// The worker's bounded FIFO buffer rejected a yield because
    /// it had reached capacity. Drop-newest semantics apply: the
    /// rejected document never reached the transport.
    case bufferOverflow
}
