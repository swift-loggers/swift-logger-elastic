import Foundation
import LoggerRemote

/// `RemoteTransport` adapter that bridges `swift-logger-remote`'s
/// durable delivery engine to an Elasticsearch `_bulk` endpoint.
///
/// The adapter is **batch-aggregating**: every
/// ``RemoteTransport/sendBatch(_:)`` call builds **one** NDJSON
/// `_bulk` HTTP request carrying every input item, POSTs it through
/// the injected ``BulkTransport`` seam, parses the per-item
/// response array, and projects the response back into one
/// `Result<RemoteTransportResponse, any Error>` per input item in
/// the same order as the input batch. The remote engine owns the
/// durable queue, retry budget, batch rounds, retained-artifact
/// reuse, and acknowledgement-to-removal lifecycle; the adapter
/// stores only endpoint configuration and the injected bulk
/// transport handle.
///
/// ## Ownership boundaries
///
/// `swift-logger-elastic` owns:
/// - ECS/document encoding of the host's log record into
///   `RemoteTransportBatchItem.payloadBytes`.
/// - NDJSON `_bulk` request building from the ordered input items.
/// - Elasticsearch `_bulk` response parsing and per-item result
///   projection.
///
/// `swift-logger-remote` owns:
/// - The durable queue (`DurableRemoteQueue`).
/// - The retry budget and the batch-round dispatcher.
/// - The acknowledgement-to-removal lifecycle (no destructive
///   removal until the engine acknowledges a fully-resolved
///   non-empty flush pass).
/// - The retained export artifact and outstanding-batch reuse on
///   retryable continuations.
///
/// The adapter never re-implements those concerns; it would
/// duplicate state the engine already owns and violate LGR-11.
struct ElasticRemoteTransport: RemoteTransport {
    /// Target Elasticsearch endpoint (direct cluster or intake
    /// gateway). Direct endpoints get `/_bulk` appended; intake
    /// endpoints are POSTed verbatim.
    let endpoint: ElasticEndpoint

    /// Data-stream / index name written into every `create` action
    /// line of the `_bulk` request body. Defaults to the ECS
    /// data-stream convention `logs-swift-loggers-default` so it
    /// matches the `event.dataset` field stamped by ``ECSEncoder``.
    let indexName: String

    /// HTTP client seam used to dispatch the `_bulk` request. The
    /// `URLSession`-backed initializer wires this to
    /// ``URLSessionBulkTransport``; the seam-injecting initializer
    /// takes a custom transport so tests can record without
    /// touching the network.
    private let transport: any BulkTransport

    /// Constructs an adapter that dispatches every `_bulk` request
    /// through `URLSession`. The session defaults to `.shared` so
    /// callers can plug in a custom configuration (e.g. a
    /// per-process session with a tighter timeout) by injecting
    /// their own `URLSession`.
    init(
        endpoint: ElasticEndpoint,
        indexName: String = "logs-swift-loggers-default",
        urlSession: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.indexName = indexName
        transport = URLSessionBulkTransport(session: urlSession)
    }

    /// Test-only initializer that swaps the HTTP seam for a custom
    /// ``BulkTransport`` implementation. Marked `internal` because
    /// ``BulkTransport`` is the package-internal transport contract;
    /// the public surface only exposes the `URLSession`-backed
    /// shape.
    init(
        endpoint: ElasticEndpoint,
        indexName: String,
        transport: any BulkTransport
    ) {
        self.endpoint = endpoint
        self.indexName = indexName
        self.transport = transport
    }

    /// Dispatches the input batch as one Elasticsearch `_bulk`
    /// request and returns one `Result` per input item in input
    /// order.
    ///
    /// **Per-item independence.** One item's permanent failure
    /// (`400` mapper parsing exception, etc.) does not poison
    /// sibling items' results; the adapter projects each entry of
    /// the response's `items` array into its own per-input
    /// `Result`. The engine then routes each result through
    /// ``classify(_:)`` and the engine's batch-round dispatcher
    /// shrinks the active set to retryable items for the next
    /// round.
    ///
    /// **Whole-batch failure routing.** Anything that prevents a
    /// well-formed per-item projection — non-2xx HTTP status,
    /// network error, malformed response body, item count mismatch
    /// — throws from `sendBatch`. The engine treats the throw as a
    /// transport-level failure for every item in the call and runs
    /// each item through ``classify(_:)`` with `.failure(error)`.
    func sendBatch(
        _ items: [RemoteTransportBatchItem]
    ) async throws -> [Result<RemoteTransportResponse, any Error>] {
        let body = try NDJSONBulkBody.make(
            documents: items.map(\.payloadBytes),
            indexName: indexName
        )

        var headers = ["Content-Type": "application/x-ndjson"]
        if let authorization = endpoint.authorizationHeaderValue {
            headers["Authorization"] = authorization
        }

        // HTTP non-2xx, network, TLS, and DNS failures throw from
        // the BulkTransport seam. We let those propagate so the
        // engine routes the whole batch through `classify(_:)`.
        let responseBody = try await transport.send(
            url: endpoint.requestURL,
            headers: headers,
            body: body
        )

        // Intake endpoints are consumer-owned proxies whose response
        // body is opaque by design (the intake is free to return
        // any 2xx body it likes — empty, a vendor envelope, etc.).
        // A 2xx HTTP round-trip is the full success signal for the
        // core adapter; per-item results all succeed with identical
        // opaque response bytes.
        //
        // The intake proxy owns per-item validation and any
        // partial-failure response: this adapter does NOT parse the
        // intake's response body and cannot distinguish per-item
        // outcomes. If the intake needs partial-failure semantics
        // (some items accepted, some rejected), it must enforce
        // that downstream (typically by holding back the request
        // and replying non-2xx, or by surfacing item-level outcomes
        // through its own out-of-band channel — neither of which
        // the core adapter sees).
        if case .intake = endpoint {
            let opaqueResponse = RemoteTransportResponse(responseBytes: responseBody)
            return items.map { _ in .success(opaqueResponse) }
        }

        // Direct cluster endpoint: parse the documented `_bulk`
        // response shape and project per-item.
        let parsedItems = try ElasticBulkResponseParser.parse(responseBody)
        guard parsedItems.count == items.count else {
            throw ElasticBulkError.responseItemCountMismatch(
                expected: items.count, actual: parsedItems.count
            )
        }
        return parsedItems.map { parsedItem in
            switch parsedItem.classification {
            case .success:
                return .success(RemoteTransportResponse(responseBytes: Data()))
            case .retryable:
                return .failure(ElasticItemFailure.retryable(
                    action: parsedItem.action,
                    status: parsedItem.status,
                    errorType: parsedItem.errorType
                ))
            case .terminal:
                return .failure(ElasticItemFailure.terminal(
                    action: parsedItem.action,
                    status: parsedItem.status,
                    errorType: parsedItem.errorType
                ))
            }
        }
    }

    /// Maps a per-item `Result` from ``sendBatch(_:)`` (or a
    /// whole-batch `.failure(error)` raised by a `sendBatch` throw)
    /// into a `RemoteDeliveryResult` the engine consumes.
    ///
    /// **Sink-owned.** The engine never inspects HTTP status,
    /// vendor body codes, or transport error types (LGR-5 / LGR-7
    /// / LGR-9); the mapping below is the adapter's
    /// authoritative rule:
    ///
    /// - `.success(_)` → `.success` (item-level `_bulk` accept).
    /// - `.failure(ElasticItemFailure.terminal)` → `.terminal`
    ///   (permanent per-item rejection, e.g. `400` mapper parsing
    ///   exception).
    /// - `.failure(ElasticItemFailure.retryable)` → `.retryable`
    ///   (transient per-item rejection, e.g. `429` / `503`).
    /// - `.failure(ElasticBulkError)` (malformed response, count
    ///   mismatch, missing status) → `.retryable`. A malformed
    ///   response is more often a misconfigured proxy than a
    ///   permanent backend rejection; let the engine's retry
    ///   budget cover it.
    /// - `.failure(BulkTransportError.unsuccessfulStatus(4xx))`
    ///   other than `408` and `429` → `.terminal` (auth / URL bug
    ///   — retrying with the same credentials and endpoint will
    ///   not help).
    /// - `.failure(BulkTransportError.unsuccessfulStatus(408))` →
    ///   `.retryable` (request-timeout class — transport/round-trip
    ///   timeout signal, not a permanent adapter misconfiguration).
    /// - `.failure(BulkTransportError.unsuccessfulStatus(429))` →
    ///   `.retryable` (whole-request backpressure — Elasticsearch
    ///   rate-limit / queue-exhaustion signal at the cluster level,
    ///   mirroring the item-level `429` mapping).
    /// - `.failure(BulkTransportError.unsuccessfulStatus(5xx))` →
    ///   `.retryable`.
    /// - Any other `.failure(_)` (URLError, DNS, TLS,
    ///   cancellation, …) → `.retryable`.
    func classify(
        _ result: Result<RemoteTransportResponse, any Error>
    ) async -> RemoteDeliveryResult {
        switch result {
        case .success:
            return .success
        case let .failure(error):
            return Self.classify(error: error)
        }
    }

    /// Pure classification of an error value. Split from
    /// ``classify(_:)`` so the test target can exercise the
    /// mapping table without constructing `Result.failure`
    /// wrappers per case.
    static func classify(error: any Error) -> RemoteDeliveryResult {
        if let itemFailure = error as? ElasticItemFailure {
            switch itemFailure {
            case .retryable:
                return .retryable(reason: .transportRejected)
            case .terminal:
                return .terminal(reason: .transportRejected)
            }
        }
        if error is ElasticBulkError {
            return .retryable(reason: .transportRejected)
        }
        if let transportError = error as? BulkTransportError {
            switch transportError {
            case let .unsuccessfulStatus(status)
                where (400 ..< 500).contains(status) && status != 408 && status != 429:
                // 4xx other than 408 and 429 is a permanent
                // rejection: auth failure, malformed request,
                // missing index without create-on-write — retrying
                // with the same request shape and credentials will
                // not help. 408 (request timeout, transport class)
                // and 429 (backpressure) are transient and fall
                // through to the retryable branch below alongside
                // 5xx.
                return .terminal(reason: .transportRejected)
            case .unsuccessfulStatus, .invalidResponse, .bulkItemFailures, .malformedBulkResponse:
                // `bulkItemFailures` comes from the shared
                // BulkTransport taxonomy used by the best-effort
                // top-level envelope validator. Keep it retryable
                // here for compatibility even though the durable
                // direct path normally projects item failures
                // through `ElasticBulkResponseParser`.
                return .retryable(reason: .transportRejected)
            }
        }
        return .retryable(reason: .transportRejected)
    }
}
