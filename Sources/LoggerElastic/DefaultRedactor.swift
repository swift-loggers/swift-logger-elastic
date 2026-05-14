import Foundation
import Loggers

/// Internal redactor that strips private and sensitive content from a
/// ``LogRecord`` before any encoding or persistence step.
///
/// `DefaultRedactor` is internal to the package. It runs on every
/// record the best-effort `ElasticLogger` path emits, ahead of
/// ECS encoding and ahead of the worker's bounded buffer; the
/// durable `ElasticRemoteEngine` path does not invoke this
/// redactor because callers there hand pre-encoded `_bulk`
/// document bytes to `DurableRemoteQueue.enqueue(_:)` directly and
/// own any redaction upstream of enqueue. Callers using the durable
/// path must redact before `DurableRemoteQueue.enqueue(_:)`.
///
/// The redactor enforces the privacy contract documented on the core
/// types:
///
/// | Privacy       | Output                                    |
/// |---------------|-------------------------------------------|
/// | `.public`     | content kept verbatim                     |
/// | `.private`    | replaced with the literal `<private>`     |
/// | `.sensitive`  | replaced with the literal `<redacted>`    |
///
/// After redaction the returned record carries only `.public`
/// segments and `.public` attribute values, so any downstream
/// encoder can ignore privacy annotations and treat the payload as
/// safe-to-emit text. Running the redactor before encoding is a hard
/// invariant on the `ElasticLogger` path: the in-process worker
/// only ever sees redacted records, so a leaked plaintext value
/// cannot reach the bounded buffer or the wire.
struct DefaultRedactor: Sendable {
    /// Returns a copy of `record` with private and sensitive content
    /// replaced by the redacted literals.
    ///
    /// - The message is collapsed into a single `.public` segment
    ///   whose text equals ``LogMessage/redactedDescription``.
    /// - Each attribute keeps its key. A `.public` attribute keeps
    ///   its value verbatim. A `.private` attribute is rewritten to
    ///   `.string("<private>")`, and a `.sensitive` attribute to
    ///   `.string("<redacted>")`. After redaction every attribute is
    ///   tagged `.public`.
    /// - The timestamp, level, and domain are preserved.
    func redact(_ record: LogRecord) -> LogRecord {
        let redactedMessage = LogMessage(segments: [
            LogSegment(record.message.redactedDescription, privacy: .public)
        ])

        let redactedAttributes = record.attributes.map(redact)

        return LogRecord(
            timestamp: record.timestamp,
            level: record.level,
            domain: record.domain,
            message: redactedMessage,
            attributes: redactedAttributes
        )
    }

    private func redact(_ attribute: LogAttribute) -> LogAttribute {
        switch attribute.privacy {
        case .public:
            return attribute
        case .private:
            return LogAttribute(attribute.key, .string("<private>"), privacy: .public)
        case .sensitive:
            return LogAttribute(attribute.key, .string("<redacted>"), privacy: .public)
        @unknown default:
            // Fail closed: unknown privacy from a future swift-logger
            // release is treated as the strictest known label so a
            // value cannot leak before this adapter is updated.
            return LogAttribute(attribute.key, .string("<redacted>"), privacy: .public)
        }
    }
}
