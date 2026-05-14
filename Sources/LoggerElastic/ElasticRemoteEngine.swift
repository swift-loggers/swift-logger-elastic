import Foundation
import LoggerRemote

/// Factory namespace that wires the Elastic-side `RemoteTransport`
/// adapter to the engine surface exposed by `swift-logger-remote`.
///
/// Hosts that opt into durable Elastic delivery call ``make(_:)``
/// once during startup to build the `RemoteEngine` +
/// `DurableRemoteQueue` pair backing Elastic-bound log delivery.
/// Each subsequent host-driven `flush()` runs one batch-round
/// dispatch pass through the internal Elastic `RemoteTransport`
/// adapter; the engine owns the durable queue, retry budget,
/// batch rounds, retained-artifact reuse, and the
/// acknowledgement-to-removal lifecycle.
///
/// The factory deliberately stays narrow: it returns the
/// `RemoteEngine` actor plus its backing `DurableRemoteQueue` so
/// the caller can `enqueue(_:)` directly without re-deriving the
/// queue handle from the engine. Hosts wire `flush()` calls from
/// their own lifecycle hooks (background notifications, shutdown
/// signals, periodic tasks); the factory installs no platform
/// observer of its own.
///
/// ## Payload contract
///
/// `DurableRemoteQueue.enqueue(_:)` admits a `RemoteDeliveryEntry`
/// whose `payload` is **opaque pre-encoded bytes**. For this
/// Elastic wiring those bytes are the **one Elasticsearch
/// `_bulk` document line** — the engine and the internal Elastic
/// transport never ECS-encode upstream-host log records on the
/// caller's behalf. Hosts (or a thin ECS-encoding helper on the
/// host side) build the JSON document for each entry before
/// `enqueue`; the transport appends the action line
/// (`{"create":{"_index":"..."}}`) and frames the body as NDJSON.
public enum ElasticRemoteEngine {
    /// Wiring carried by ``make(_:)`` so the caller has both the
    /// `RemoteEngine` actor that runs the flush pass and the
    /// `DurableRemoteQueue` handle that admits new entries through
    /// `enqueue(_:)`. The transport instance is held by the engine
    /// internally and is intentionally not surfaced here so the
    /// factory's public shape stays narrow.
    public struct Wiring: Sendable {
        public let queue: DurableRemoteQueue
        public let engine: RemoteEngine
    }

    /// Caller-facing configuration for the durable Elastic wiring.
    ///
    /// The struct stays plain-data so hosts that already manage
    /// their own configuration objects can map their fields onto
    /// this contract without re-deriving engine policy types.
    public struct Configuration: Sendable {
        /// Target Elasticsearch endpoint (direct cluster or intake
        /// gateway).
        public let endpoint: ElasticEndpoint
        /// Data-stream / index name written into every `_bulk`
        /// action line. Defaults to the ECS data-stream convention
        /// `logs-swift-loggers-default` so it lines up with the
        /// `event.dataset` field a host-side ECS encoder would
        /// stamp on every document.
        public let indexName: String
        /// Host-owned queue directory. Persistence-backed durable
        /// queue lives here; the engine never deletes the
        /// directory itself, only the persistence layer it owns.
        public let queueDirectory: URL
        /// Host-owned scratch directory the engine writes
        /// byte-stable exports into during `flush()`. Must be
        /// engine-exclusive (no other process or actor touches the
        /// files inside).
        public let exportDirectory: URL
        /// Batch boundary policy: max entry count and max byte
        /// count the batching engine respects per dispatched
        /// `_bulk` round.
        public let batchPolicy: RemoteBatchPolicy
        /// Per-entry retry budget and backoff schedule. The engine
        /// applies the policy across batch rounds within one
        /// flush pass.
        public let retryPolicy: RemoteRetryPolicy
        /// URLSession the transport dispatches through. Hosts that
        /// want a custom timeout, connection limit, or proxy
        /// configuration inject their own session here.
        public let urlSession: URLSession

        public init(
            endpoint: ElasticEndpoint,
            indexName: String = "logs-swift-loggers-default",
            queueDirectory: URL,
            exportDirectory: URL,
            batchPolicy: RemoteBatchPolicy,
            retryPolicy: RemoteRetryPolicy,
            urlSession: URLSession = .shared
        ) {
            self.endpoint = endpoint
            self.indexName = indexName
            self.queueDirectory = queueDirectory
            self.exportDirectory = exportDirectory
            self.batchPolicy = batchPolicy
            self.retryPolicy = retryPolicy
            self.urlSession = urlSession
        }
    }

    /// Builds the `RemoteEngine` + `DurableRemoteQueue` +
    /// `ElasticRemoteTransport` wiring from `configuration`.
    /// Pure factory: no I/O, no side effects beyond constructing
    /// the actor instances. Queue persistence touches disk only
    /// when the returned queue or engine is later used.
    public static func make(_ configuration: Configuration) -> Wiring {
        let transport = ElasticRemoteTransport(
            endpoint: configuration.endpoint,
            indexName: configuration.indexName,
            urlSession: configuration.urlSession
        )
        return wire(configuration: configuration, transport: transport)
    }

    /// Test-only factory that swaps the HTTP seam for a custom
    /// ``BulkTransport`` implementation. Marked `internal` because
    /// ``BulkTransport`` is the package-internal transport contract;
    /// the public surface only exposes the `URLSession`-backed
    /// shape through ``make(_:)``.
    static func make(
        _ configuration: Configuration,
        bulkTransport: any BulkTransport
    ) -> Wiring {
        let transport = ElasticRemoteTransport(
            endpoint: configuration.endpoint,
            indexName: configuration.indexName,
            transport: bulkTransport
        )
        return wire(configuration: configuration, transport: transport)
    }

    private static func wire(
        configuration: Configuration,
        transport: ElasticRemoteTransport
    ) -> Wiring {
        let queue = DurableRemoteQueue(directory: configuration.queueDirectory)
        let engine = RemoteEngine(
            queue: queue,
            exportDirectory: configuration.exportDirectory,
            transport: transport,
            batchPolicy: configuration.batchPolicy,
            retryPolicy: configuration.retryPolicy
        )
        return Wiring(queue: queue, engine: engine)
    }
}
