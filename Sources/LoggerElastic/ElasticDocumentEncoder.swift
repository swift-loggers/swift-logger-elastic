import Foundation
import Loggers

/// Sink-owned `_bulk` document encoder for the best-effort
/// ``ElasticLogger`` path. The default
/// ``DefaultElasticDocumentEncoder`` emits Elastic Common Schema
/// JSON; custom conformances are free to emit any single-line
/// JSON document shape that satisfies the returned-bytes
/// contract below.
///
/// The encoder runs after the configured ``ElasticRecordRedactor``
/// has replaced private and sensitive segments and before the
/// bounded FIFO worker. It returns the JSON **document** bytes the
/// adapter wraps in NDJSON `_bulk` action + document framing.
///
/// **Returned-bytes contract:**
///
/// - Encoders return **one compact single-line JSON document**.
/// - Encoders MUST NOT emit the `_bulk` action line themselves —
///   the adapter prepends `{"create":{"_index":"..."}}\n` on the
///   wire.
/// - Encoders MUST NOT include raw newline (`0x0A`) bytes
///   anywhere in the returned bytes — not as a trailing
///   terminator, not inside a pretty-printed document, not as a
///   field separator. The adapter terminates the document with
///   exactly one `0x0A` on the wire; a raw newline anywhere
///   inside the returned bytes would split one logical document
///   into multiple NDJSON lines and corrupt `_bulk` framing.
///
/// `encode(_:serviceName:)` is allowed to throw. A throwing
/// encoder is treated as a best-effort drop at the call site: the
/// entry is dropped, the underlying error is surfaced through the
/// ``ElasticLogger``'s `onDiagnostic` callback as
/// ``ElasticLoggerDiagnostic/encodingFailed(_:)``, and the logger
/// continues processing later entries. `ElasticLogger.log` stays
/// synchronous and infallible regardless of encoder behaviour.
///
/// **Concurrency.** `encode(_:serviceName:)` may be invoked
/// concurrently from multiple threads when concurrent
/// `ElasticLogger.log` calls fire. Custom encoders MUST be
/// reentrant and thread-safe; the default
/// ``DefaultElasticDocumentEncoder`` satisfies this contract.
///
/// The durable ``ElasticRemoteEngine`` path does not invoke this
/// encoder. Durable callers hand pre-encoded `_bulk` document bytes
/// to `DurableRemoteQueue.enqueue(_:)` directly and own document
/// encoding upstream of enqueue.
public protocol ElasticDocumentEncoder: Sendable {
    /// Returns the JSON document bytes for `record`. The bytes
    /// are wrapped by the adapter in the NDJSON `_bulk` envelope
    /// (`{"create":{"_index":"..."}}\n<document>\n`); encoders
    /// emit only the document half.
    func encode(_ record: LogRecord, serviceName: String) throws -> Data
}

/// Default ``ElasticDocumentEncoder`` used by ``ElasticLogger``
/// when no custom encoder is injected.
///
/// The default encoder serialises the redacted `LogRecord` into
/// Elastic Common Schema (ECS) JSON: `@timestamp`, `log.level`,
/// `message`, `service.name`, `event.dataset` (`swift-loggers`),
/// `logger.domain`, plus any user attributes as top-level dotted
/// keys (attributes whose key collides with one of the reserved
/// ECS fields are moved into a nested `labels` object). The
/// default encoder is **total**: every supported `LogValue` case
/// maps to a JSON-native value, non-finite `Double` values are
/// coerced to JSON `null`, and the result is always a valid JSON
/// object — `encode(_:serviceName:)` does not throw.
public struct DefaultElasticDocumentEncoder: ElasticDocumentEncoder {
    private let inner: ECSEncoder

    public init() {
        inner = ECSEncoder()
    }

    public func encode(_ record: LogRecord, serviceName: String) -> Data {
        inner.encode(record, serviceName: serviceName)
    }
}
