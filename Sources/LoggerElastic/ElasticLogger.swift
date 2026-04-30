import Foundation
import Loggers

/// A `Logger` adapter targeting a first-party Elasticsearch intake /
/// proxy endpoint.
///
/// ## Status: M3.0 scaffolding
///
/// This release ships only the locked public surface. The drop guard
/// is wired up: entries below the configured threshold and entries at
/// `LoggerLevel.disabled` are dropped without evaluating the message
/// or attributes autoclosures. **Allowed entries are accepted and
/// discarded.** Nothing is encoded, no network request is issued, and
/// no record reaches an intake URL yet.
///
/// The public initializer surface and the ``MinimumLevel`` threshold
/// are locked here so the encoder (M3.1) and the ordered delivery
/// pipeline (M3.2) can be filled in without breaking call sites.
///
/// ## Planned behavior (M3.1, M3.2)
///
/// Once the follow-up milestones land, this adapter will:
///
/// - materialize and redact each allowed entry,
/// - encode it as Elastic Common Schema (ECS) JSON, and
/// - POST it to ``intakeURL`` through an ordered delivery pipeline
///   with batching, retry, flush-on-lifecycle, and bounded
///   backpressure.
///
/// The universal `Logger` contract stays synchronous; ordering is
/// the adapter's responsibility, not the call site's.
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
    /// will be POSTed here; in the M3.0 scaffold the URL is stored
    /// but no request is issued.
    public let intakeURL: URL

    /// The value the M3.1 encoder will stamp as the `service.name`
    /// field on every emitted record. Typically the app or library
    /// name, for example `"demo-ios"`. Stored verbatim by the M3.0
    /// scaffold; not yet read by any encoder.
    public let serviceName: String

    /// The drop-guard threshold for this logger. Entries whose
    /// severity is strictly lower than this value -- and entries at
    /// `LoggerLevel.disabled` -- are dropped without evaluating the
    /// message or attributes autoclosures. Entries at or above this
    /// value pass the drop guard; in M3.0 they are accepted and
    /// discarded, and once M3.1 / M3.2 land they will be redacted,
    /// encoded, and POSTed to ``intakeURL``.
    public let minimumLevel: MinimumLevel

    /// Creates an `ElasticLogger`.
    ///
    /// - Parameters:
    ///   - intakeURL: The first-party intake / proxy endpoint. Must
    ///     not be a direct Elasticsearch endpoint that requires an
    ///     API key embedded in the client.
    ///   - serviceName: The value the M3.1 encoder will stamp as
    ///     the `service.name` field on every emitted record.
    ///     Stored verbatim by the M3.0 scaffold and not yet read.
    ///   - minimumLevel: The minimum severity to emit. Defaults to
    ///     ``MinimumLevel/defaultLevel``.
    public init(
        intakeURL: URL,
        serviceName: String,
        minimumLevel: MinimumLevel = .defaultLevel
    ) {
        self.intakeURL = intakeURL
        self.serviceName = serviceName
        self.minimumLevel = minimumLevel
    }

    public func log(
        _ level: LoggerLevel,
        _: LoggerDomain,
        _: @autoclosure @escaping @Sendable () -> LogMessage,
        attributes _: @autoclosure @escaping @Sendable () -> [LogAttribute]
    ) {
        guard shouldEmit(level) else { return }
        // M3.0 placeholder: the drop guard is wired up so call sites
        // can already integrate. Materialization, redaction, encoding,
        // and ordered enqueue land in M3.1 and M3.2.
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
