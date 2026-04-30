import Foundation
import Loggers

/// Internal redactor that strips private and sensitive content from a
/// ``LogRecord`` before any encoding or persistence step.
///
/// `DefaultRedactor` is intentionally not part of the public surface
/// in M3.1. The contract for a swappable redactor is held back until
/// the shared remote-adapter API is informed by an actual delivery
/// pipeline (M3.2) and a second sink, so the protocol shape can be
/// driven by real needs rather than frozen prematurely.
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
/// invariant: the M3.2 delivery pipeline will only see redacted
/// records, so a leaked plaintext value cannot reach a retry queue,
/// disk persistence, or the wire.
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
