import Foundation
import Loggers

/// Sink-owned privacy redactor for the best-effort
/// ``ElasticLogger`` path. Receives the host's `LogRecord` before
/// any encoding step and returns a record whose message and
/// attribute values carry only `.public` privacy.
///
/// Redaction is the **first** step on the `ElasticLogger` pipeline:
/// it runs before ``ElasticDocumentEncoder/encode(_:serviceName:)``
/// and before the worker's bounded FIFO buffer, so plaintext
/// private / sensitive content cannot leak into the buffer, the
/// encoder, or the transport even when later steps fail.
///
/// The durable ``ElasticRemoteEngine`` path does not invoke this
/// redactor. Durable callers redact upstream of
/// `DurableRemoteQueue.enqueue(_:)`; the engine never observes the
/// host record and never re-renders private content from queued
/// bytes.
///
/// Custom redactors SHOULD remain **fail-closed for unknown
/// privacy** — see ``DefaultElasticRecordRedactor`` — so a new
/// privacy case added by a future `swift-logger` release cannot
/// silently leak through the adapter before the custom redactor is
/// updated.
public protocol ElasticRecordRedactor: Sendable {
    /// Returns a redacted copy of `record`. The returned record
    /// MUST carry `.public` privacy on every message segment and
    /// every attribute value.
    func redact(_ record: LogRecord) -> LogRecord
}

/// Default ``ElasticRecordRedactor`` used by ``ElasticLogger``
/// when no custom redactor is injected.
///
/// Enforces the privacy contract documented on the core types:
///
/// | Privacy       | Output                                    |
/// |---------------|-------------------------------------------|
/// | `.public`     | content kept verbatim                     |
/// | `.private`    | replaced with the literal `<private>`     |
/// | `.sensitive`  | replaced with the literal `<redacted>`    |
///
/// Unknown privacy from a future `swift-logger` release is
/// **fail-closed to `<redacted>`** so a value cannot leak before
/// this adapter is updated.
public struct DefaultElasticRecordRedactor: ElasticRecordRedactor {
    private let inner: DefaultRedactor

    public init() {
        inner = DefaultRedactor()
    }

    public func redact(_ record: LogRecord) -> LogRecord {
        inner.redact(record)
    }
}
