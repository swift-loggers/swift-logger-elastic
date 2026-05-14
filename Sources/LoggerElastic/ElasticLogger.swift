import Foundation
import Loggers

/// A `Logger` adapter that materializes, redacts, encodes through
/// the configured ``ElasticDocumentEncoder``, and enqueues each
/// allowed entry for best-effort delivery to an Elasticsearch
/// cluster directly or to a consumer-owned intake / proxy
/// endpoint. Accepted entries are drained from a bounded
/// FIFO buffer toward the transport; the adapter does not
/// guarantee that every enqueued entry reaches the destination.
///
/// For each allowed entry the adapter:
///
/// 1. evaluates the `message` and `attributes` autoclosures exactly
///    once,
/// 2. builds a `LogRecord` stamped with a wall-clock timestamp,
/// 3. runs the record through the configured ``ElasticRecordRedactor``
///    so private and sensitive content is replaced before the
///    record reaches any later step,
/// 4. hands the redacted record to the configured
///    ``ElasticDocumentEncoder`` to produce the `_bulk` document
///    bytes (``DefaultElasticDocumentEncoder`` emits Elastic
///    Common Schema JSON; a custom encoder may emit its own
///    document shape), and
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
/// HTTP errors, malformed direct `_bulk` responses / invalid
/// envelopes / item-count mismatches, top-level `_bulk` error
/// responses, network timeouts, the device being offline -- are
/// dropped on the floor; the buffer lives only in memory, so
/// reconnecting (or relaunching the app) does not replay
/// previously failed payloads.
///
/// `ElasticLogger` is the best-effort path; hosts that need
/// durable delivery, retry, or per-failure diagnostics use
/// ``ElasticRemoteEngine`` instead. The public customization
/// surface on this path is locked at three seams:
/// ``ElasticDocumentEncoder`` (document encoding),
/// ``ElasticRecordRedactor`` (privacy redaction before encoding),
/// and the ``ElasticLoggerDiagnostic`` `onDiagnostic` callback
/// (encoder failures, bounded-buffer overflow). The transport and
/// FIFO worker stay internal; the surface is narrow because the
/// best-effort contract is the entire contract — there is no
/// swappable retry / batching layer to configure here.
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

    /// The destination encoded `_bulk` documents are POSTed to and
    /// the credentials used to reach it. See ``ElasticEndpoint``
    /// for the two supported delivery shapes (direct Elasticsearch
    /// and consumer-owned intake).
    public let endpoint: ElasticEndpoint

    /// The value passed to the configured
    /// ``ElasticDocumentEncoder``;
    /// ``DefaultElasticDocumentEncoder`` emits it as the ECS
    /// `service.name` field on every encoded document, while
    /// custom encoders are free to project it differently or
    /// ignore it. Typically the app or library name, for example
    /// `"demo-ios"`.
    public let serviceName: String

    /// The drop-guard threshold for this logger. Entries whose
    /// severity is strictly lower than this value -- and entries at
    /// `LoggerLevel.disabled` -- are dropped without evaluating the
    /// message or attributes autoclosures. Entries at or above this
    /// value are materialized, redacted, encoded by the configured
    /// ``ElasticDocumentEncoder``, and enqueued
    /// onto the worker's bounded buffer. Only entries the buffer
    /// accepts are drained toward the configured ``ElasticEndpoint``;
    /// entries the buffer drops under sustained overload never reach
    /// the transport. Even accepted entries are delivered on a
    /// best-effort basis without retry or durability.
    public let minimumLevel: MinimumLevel

    private let dateProvider: @Sendable () -> Date
    private let redactor: any ElasticRecordRedactor
    private let encoder: any ElasticDocumentEncoder
    private let onDiagnostic: (@Sendable (ElasticLoggerDiagnostic) -> Void)?
    private let worker: DeliveryWorker

    /// Creates an `ElasticLogger` that POSTs encoded `_bulk`
    /// documents to the supplied ``ElasticEndpoint``.
    ///
    /// - Parameters:
    ///   - endpoint: The delivery destination plus credentials. See
    ///     ``ElasticEndpoint`` for direct vs intake semantics and
    ///     for the trust-model trade-offs.
    ///   - serviceName: The value passed to the configured
    ///     ``ElasticDocumentEncoder``;
    ///     ``DefaultElasticDocumentEncoder`` emits it as the ECS
    ///     `service.name` field on every encoded document.
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
    ///   - encoder: The ``ElasticDocumentEncoder`` used to turn
    ///     each redacted `LogRecord` into `_bulk` document
    ///     bytes. Defaults to ``DefaultElasticDocumentEncoder``,
    ///     which emits Elastic Common Schema JSON. A custom
    ///     encoder is allowed to throw; throws are reported as
    ///     ``ElasticLoggerDiagnostic/encodingFailed(_:)`` and the
    ///     entry is dropped without breaking later entries.
    ///   - redactor: The ``ElasticRecordRedactor`` invoked before
    ///     encoding. Defaults to ``DefaultElasticRecordRedactor``,
    ///     which is fail-closed for unknown privacy. Runs before
    ///     the worker's bounded buffer so plaintext private /
    ///     sensitive content cannot leak even when later steps
    ///     fail.
    ///   - onDiagnostic: Optional observer for
    ///     ``ElasticLoggerDiagnostic`` signals (encoder failures,
    ///     bounded-buffer overflow). Fired synchronously on the
    ///     producer thread that triggered the signal; the
    ///     `log(_:_:_:attributes:)` contract stays synchronous and
    ///     infallible regardless.
    public init(
        endpoint: ElasticEndpoint,
        serviceName: String,
        minimumLevel: MinimumLevel = .defaultLevel,
        urlSession: URLSession = .shared,
        encoder: any ElasticDocumentEncoder = DefaultElasticDocumentEncoder(),
        redactor: any ElasticRecordRedactor = DefaultElasticRecordRedactor(),
        onDiagnostic: (@Sendable (ElasticLoggerDiagnostic) -> Void)? = nil
    ) {
        self.init(
            endpoint: endpoint,
            serviceName: serviceName,
            minimumLevel: minimumLevel,
            dateProvider: { Date() },
            transport: URLSessionBulkTransport(session: urlSession),
            encoder: encoder,
            redactor: redactor,
            onDiagnostic: onDiagnostic
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
        transport: any BulkTransport,
        encoder: any ElasticDocumentEncoder = DefaultElasticDocumentEncoder(),
        redactor: any ElasticRecordRedactor = DefaultElasticRecordRedactor(),
        onDiagnostic: (@Sendable (ElasticLoggerDiagnostic) -> Void)? = nil,
        queueCapacity: Int = DeliveryWorker.defaultQueueCapacity
    ) {
        self.endpoint = endpoint
        self.serviceName = serviceName
        self.minimumLevel = minimumLevel
        self.dateProvider = dateProvider
        self.redactor = redactor
        self.encoder = encoder
        self.onDiagnostic = onDiagnostic
        let onBufferOverflow: @Sendable () -> Void = {
            onDiagnostic?(.bufferOverflow)
        }
        worker = DeliveryWorker(
            transport: transport,
            endpoint: endpoint,
            queueCapacity: queueCapacity,
            onBufferOverflow: onBufferOverflow
        )
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
        let encoded: Data
        do {
            encoded = try encoder.encode(redacted, serviceName: serviceName)
        } catch {
            // Best-effort drop: the encoder rejected this entry.
            // Surface the failure through the diagnostic callback
            // so hosts can observe it without breaking the
            // synchronous infallible `log` contract; keep
            // processing later entries.
            onDiagnostic?(.encodingFailed(error))
            return
        }
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
