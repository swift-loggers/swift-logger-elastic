import Foundation
import Loggers

/// A `Logger` adapter that materializes, redacts, ECS-encodes, and
/// enqueues each allowed entry for best-effort delivery to an
/// Elasticsearch cluster directly or to a consumer-owned intake /
/// proxy endpoint. Accepted entries are drained from a bounded
/// FIFO buffer toward the transport; the adapter does not
/// guarantee that every enqueued entry reaches the destination.
///
/// For each allowed entry the adapter:
///
/// 1. evaluates the `message` and `attributes` autoclosures exactly
///    once,
/// 2. builds a `LogRecord` stamped with a wall-clock timestamp,
/// 3. runs the record through an internal redactor that replaces
///    private segments and attribute values with `<private>` and
///    sensitive ones with `<redacted>`,
/// 4. encodes the redacted record as Elastic Common Schema (ECS)
///    JSON, and
/// 5. enqueues the encoded payload onto an ordered FIFO worker
///    that POSTs an NDJSON `_bulk` body to the configured
///    ``ElasticEndpoint``.
///
/// Entries strictly below the configured ``MinimumLevel`` and
/// entries at `LoggerLevel.disabled` are dropped without evaluating
/// the message or attributes autoclosures, and never reach the
/// transport. The `Logger` protocol contract stays synchronous;
/// ordering is the adapter's responsibility, not the call site's.
///
/// The internal FIFO queue is bounded. When the consumer cannot
/// keep up (slow network, offline transport) the worker keeps the
/// oldest queued payloads moving and **drops new entries on the
/// producer side** once the buffer hits its capacity (1000
/// payloads by default). Payloads that fail to deliver --
/// HTTP errors, top-level `_bulk` error responses, network timeouts,
/// the device being offline -- are dropped on the floor; the
/// buffer lives only in memory, so reconnecting (or relaunching
/// the app) does not replay previously failed payloads.
///
/// `ElasticLogger` is the best-effort path; hosts
/// that need durable delivery, retry, or per-failure diagnostics
/// use ``ElasticRemoteEngine`` instead. The encoder, redactor,
/// transport, and FIFO worker are intentionally internal on this
/// path; the surface stays narrow because the best-effort contract
/// is the entire contract — there is no swappable retry / batching
/// layer to configure here.
///
/// ## Threat model
///
/// `ElasticEndpoint.elasticsearch(url:apiKey:)` is a supported
/// **informed opt-in**: an API key compiled into a client app
/// binary is extractable, so the cluster behind that key inherits
/// the trust level of the distribution channel. Direct mode is
/// appropriate for trial setups, smoke tests, internal-only apps,
/// prototypes, and any context where the operator has consciously
/// accepted that risk.
///
/// `ElasticEndpoint.intake(url:authorizationHeader:)` is the
/// recommended hardened-production shape. The intake URL is a
/// consumer-owned proxy / gateway / APM endpoint; the real cluster
/// credential lives on the server side and never ships with the
/// client. Bearer, Basic, custom gateway tokens, or no auth are
/// supported through `.intake(url:authorizationHeader:)` because
/// the intake endpoint is consumer-owned.
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

    /// The destination encoded ECS records are POSTed to and the
    /// credentials used to reach it. See ``ElasticEndpoint`` for
    /// the two supported delivery shapes (direct Elasticsearch and
    /// consumer-owned intake).
    public let endpoint: ElasticEndpoint

    /// The value the encoder stamps as the ECS `service.name` field
    /// on every encoded record. Typically the app or library name,
    /// for example `"demo-ios"`.
    public let serviceName: String

    /// The drop-guard threshold for this logger. Entries whose
    /// severity is strictly lower than this value -- and entries at
    /// `LoggerLevel.disabled` -- are dropped without evaluating the
    /// message or attributes autoclosures. Entries at or above this
    /// value are materialized, redacted, ECS-encoded, and enqueued
    /// onto the worker's bounded buffer. Only entries the buffer
    /// accepts are drained toward the configured ``ElasticEndpoint``;
    /// entries the buffer drops under sustained overload never reach
    /// the transport. Even accepted entries are delivered on a
    /// best-effort basis without retry or durability.
    public let minimumLevel: MinimumLevel

    private let dateProvider: @Sendable () -> Date
    private let redactor: DefaultRedactor
    private let encoder: ECSEncoder
    private let worker: DeliveryWorker

    /// Creates an `ElasticLogger` that POSTs encoded ECS records to
    /// the supplied ``ElasticEndpoint``.
    ///
    /// - Parameters:
    ///   - endpoint: The delivery destination plus credentials. See
    ///     ``ElasticEndpoint`` for direct vs intake semantics and
    ///     for the trust-model trade-offs.
    ///   - serviceName: The value emitted as the ECS `service.name`
    ///     field on every encoded record.
    ///   - minimumLevel: The minimum severity to emit. Defaults to
    ///     ``MinimumLevel/defaultLevel``.
    ///   - urlSession: The `URLSession` used for the underlying
    ///     `_bulk` POSTs. Defaults to `URLSession.shared`. Pass a
    ///     pre-configured session here for enterprise networking
    ///     concerns -- certificate pinning or mTLS via a custom
    ///     `URLSessionDelegate`, an enterprise HTTP proxy via the
    ///     session's `URLSessionConfiguration`, custom timeout
    ///     policy, or a custom `URLProtocol`. The injected session
    ///     does not control retry, backpressure, batching, or any
    ///     of the best-effort delivery semantics this path
    ///     documents — those are fixed at the drop-newest /
    ///     no-retry / no-durable-queue contract above.
    public init(
        endpoint: ElasticEndpoint,
        serviceName: String,
        minimumLevel: MinimumLevel = .defaultLevel,
        urlSession: URLSession = .shared
    ) {
        self.init(
            endpoint: endpoint,
            serviceName: serviceName,
            minimumLevel: minimumLevel,
            dateProvider: { Date() },
            transport: URLSessionBulkTransport(session: urlSession)
        )
    }

    /// Creates an `ElasticLogger` with an injected wall-clock source
    /// and an injected transport. Internal so production callers
    /// cannot depend on either seam while tests can pin a
    /// deterministic timestamp and capture the request that the
    /// transport would have made on the network.
    init(
        endpoint: ElasticEndpoint,
        serviceName: String,
        minimumLevel: MinimumLevel = .defaultLevel,
        dateProvider: @escaping @Sendable () -> Date,
        transport: any BulkTransport
    ) {
        self.endpoint = endpoint
        self.serviceName = serviceName
        self.minimumLevel = minimumLevel
        self.dateProvider = dateProvider
        redactor = DefaultRedactor()
        encoder = ECSEncoder()
        worker = DeliveryWorker(transport: transport, endpoint: endpoint)
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
        worker.enqueue(encoded)
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
