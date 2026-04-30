import Foundation
import Loggers

/// A `Logger` adapter that materializes, redacts, and ECS-encodes
/// each allowed entry for delivery to a first-party Elasticsearch
/// intake / proxy endpoint.
///
/// ## Status: M3.1 (this release)
///
/// For each allowed entry the adapter:
///
/// 1. evaluates the `message` and `attributes` autoclosures exactly
///    once,
/// 2. builds a `LogRecord` stamped with a wall-clock timestamp,
/// 3. runs the record through an internal redactor that replaces
///    private segments and attribute values with `<private>` and
///    sensitive ones with `<redacted>`, and
/// 4. encodes the redacted record as Elastic Common Schema (ECS)
///    JSON.
///
/// The encoded `Data` is intentionally discarded today; the M3.2
/// delivery pipeline will pick it up. **M3.1 still performs no
/// network I/O.** Entries strictly below the configured
/// ``MinimumLevel`` and entries at `LoggerLevel.disabled` are
/// dropped without evaluating the message or attributes
/// autoclosures.
///
/// The encoder and redactor are intentionally internal in this
/// release; the swappable contract for them lands together with the
/// shared remote-adapter API once M3.2 and a second remote sink
/// inform the protocol shape.
///
/// ## Planned behavior (M3.2)
///
/// Once the M3.2 delivery pipeline lands, this adapter will POST
/// the encoded ECS JSON to ``intakeURL`` through an ordered queue
/// with batching, retry, flush-on-lifecycle, and bounded
/// backpressure. The universal `Logger` contract stays synchronous;
/// ordering is the adapter's responsibility, not the call site's.
///
/// ## Threat model
///
/// `intakeURL` is a **first-party intake / proxy endpoint** owned by
/// the consumer. Direct Elasticsearch endpoints take server-side API
/// keys, which must not be embedded in a client app. The primary
/// initializer therefore deliberately does **not** accept an
/// `apiKey`, `token`, or generic `headers` argument; the proxy
/// terminates client traffic and forwards to Elasticsearch with the
/// real credential server-side.
public struct ElasticLogger: Loggers.Logger {
    /// A severity threshold for ``ElasticLogger``.
    ///
    /// `MinimumLevel` is intentionally severity-only and does not
    /// include a `disabled` case: per the `LoggerLevel` contract,
    /// `disabled` is a per-message sentinel and must not be used as a
    /// threshold value. To turn off logging entirely, use a logger
    /// that drops every entry instead of configuring a threshold.
    public enum MinimumLevel: CaseIterable, Sendable {
        /// The most detailed severity, intended for fine-grained
        /// tracing.
        case trace

        /// A detailed severity intended for debugging.
        case debug

        /// An informational severity describing normal operation.
        case info

        /// A normal but significant severity worth surfacing above
        /// everyday `info` traffic.
        case notice

        /// A severity for potential issues that do not yet stop
        /// execution.
        case warning

        /// A severity for error conditions that require attention.
        case error

        /// A severity for severe conditions that require immediate
        /// attention.
        case critical

        /// The default minimum severity used when none is specified.
        ///
        /// Equal to ``MinimumLevel/warning``.
        public static let defaultLevel = MinimumLevel.warning
    }

    /// The first-party intake / proxy endpoint configured for this
    /// logger. Once the M3.2 delivery pipeline lands, encoded records
    /// will be POSTed here; in M3.1 the URL is stored but no request
    /// is issued.
    public let intakeURL: URL

    /// The value the encoder stamps as the ECS `service.name` field
    /// on every encoded record. Typically the app or library name,
    /// for example `"demo-ios"`.
    public let serviceName: String

    /// The drop-guard threshold for this logger. Entries whose
    /// severity is strictly lower than this value -- and entries at
    /// `LoggerLevel.disabled` -- are dropped without evaluating the
    /// message or attributes autoclosures. Entries at or above this
    /// value are materialized, redacted, and ECS-encoded; the
    /// encoded payload is discarded today and will be POSTed to
    /// ``intakeURL`` once the M3.2 delivery pipeline lands.
    public let minimumLevel: MinimumLevel

    /// Wall-clock source used to stamp `LogRecord.timestamp` when an
    /// allowed entry is materialized. Defaults to `Date.init`; the
    /// tests inject a fixed clock so golden ECS JSON output is
    /// byte-stable.
    private let dateProvider: @Sendable () -> Date

    /// Internal redactor applied to every materialized record before
    /// it reaches the encoder. Stateless and not configurable in M3.1.
    private let redactor: DefaultRedactor

    /// Internal ECS encoder. Stateless and not configurable in M3.1.
    private let encoder: ECSEncoder

    /// Internal sink that receives every successfully encoded payload.
    /// Defaults to a no-op so production callers see no behavior
    /// change; tests inject a recorder to assert that allowed entries
    /// reach the encoder and produce a valid ECS document. Once the
    /// M3.2 delivery pipeline lands, this seam is replaced by the
    /// ordered enqueue path and removed from the public surface.
    private let onEncoded: @Sendable (Data) -> Void

    /// Creates an `ElasticLogger`.
    ///
    /// - Parameters:
    ///   - intakeURL: The first-party intake / proxy endpoint. Must
    ///     not be a direct Elasticsearch endpoint that requires an
    ///     API key embedded in the client.
    ///   - serviceName: The value emitted as the ECS `service.name`
    ///     field on every encoded record.
    ///   - minimumLevel: The minimum severity to emit. Defaults to
    ///     ``MinimumLevel/defaultLevel``.
    public init(
        intakeURL: URL,
        serviceName: String,
        minimumLevel: MinimumLevel = .defaultLevel
    ) {
        self.init(
            intakeURL: intakeURL,
            serviceName: serviceName,
            minimumLevel: minimumLevel,
            dateProvider: { Date() },
            onEncoded: { _ in }
        )
    }

    /// Creates an `ElasticLogger` with an injected wall-clock source
    /// and an injected encoded-payload sink. Internal so production
    /// callers cannot depend on either seam while tests can pin a
    /// deterministic timestamp and observe what the encoder produces.
    init(
        intakeURL: URL,
        serviceName: String,
        minimumLevel: MinimumLevel = .defaultLevel,
        dateProvider: @escaping @Sendable () -> Date,
        onEncoded: @escaping @Sendable (Data) -> Void = { _ in }
    ) {
        self.intakeURL = intakeURL
        self.serviceName = serviceName
        self.minimumLevel = minimumLevel
        self.dateProvider = dateProvider
        self.onEncoded = onEncoded
        redactor = DefaultRedactor()
        encoder = ECSEncoder()
    }

    public func log(
        _ level: LoggerLevel,
        _ domain: LoggerDomain,
        _ message: @autoclosure @escaping @Sendable () -> LogMessage,
        attributes: @autoclosure @escaping @Sendable () -> [LogAttribute]
    ) {
        guard shouldEmit(level) else { return }
        let record = LogRecord(
            timestamp: dateProvider(),
            level: level,
            domain: domain,
            message: message(),
            attributes: attributes()
        )
        let redacted = redactor.redact(record)
        let encoded = encoder.encode(redacted, serviceName: serviceName)
        // M3.1: hand the encoded payload to the internal sink. In
        // production the sink is a no-op (network I/O lands in M3.2);
        // in tests it is a recorder that pins the integration path
        // end-to-end.
        onEncoded(encoded)
    }

    /// Returns whether an entry at the given severity passes the
    /// configured threshold. Pure and side-effect-free; used by ``log``
    /// and exercised directly in tests.
    func shouldEmit(_ level: LoggerLevel) -> Bool {
        level != .disabled && level >= minimumLevel.asLoggerLevel
    }
}

extension ElasticLogger.MinimumLevel {
    fileprivate var asLoggerLevel: LoggerLevel {
        switch self {
        case .trace: return .trace
        case .debug: return .debug
        case .info: return .info
        case .notice: return .notice
        case .warning: return .warning
        case .error: return .error
        case .critical: return .critical
        }
    }
}
