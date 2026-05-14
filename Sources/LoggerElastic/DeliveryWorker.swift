import Foundation

/// Internal FIFO worker that wraps an ECS-encoded document into a
/// two-line NDJSON `_bulk` body and sends it through the configured
/// transport.
///
/// The worker preserves the order in which yields are **accepted**
/// by the stream's bounded buffer: ``ElasticLogger/log`` calls
/// `enqueue(_:)` synchronously inside the drop guard, the call
/// yields the encoded payload onto an `AsyncStream`, and a single
/// long-running consumer task drains the stream serially. Two
/// **accepted** yields from the same producer are drained in
/// acceptance order; yields that the bounded buffer drops because
/// it is full never reach the transport at all, so the contract
/// is over what the buffer accepts, not over what the producer
/// hands in. **Concurrent producers do not receive a stronger
/// global ordering guarantee:** the stream's internal lock
/// serializes yields, but the relative order of concurrent calls
/// is whatever the runtime scheduler observes when each call
/// acquires that lock. There is no `Task { await actor.enqueue(payload) }`
/// hop on the producer side, which would let the runtime reorder
/// concurrent producers against the buffer's view of arrival.
///
/// The internal queue is **bounded**: the stream uses
/// `bufferingOldest(queueCapacity)`, so when the consumer cannot
/// keep up (slow network, offline transport) the buffer fills to
/// `queueCapacity` and subsequent yields are dropped on the floor
/// rather than accumulated without limit. The bounded buffer
/// keeps memory predictable; hosts that need durable delivery
/// with explicit retry / backpressure / acknowledgement use
/// ``ElasticRemoteEngine`` instead.
///
/// For `.elasticsearch` endpoints the worker also validates the
/// response body with the top-level `_bulk` envelope validator:
/// the `_bulk` API returns HTTP 200 with `"errors": true` when
/// Elasticsearch reports a bulk error response, so a successful
/// HTTP round-trip is not by itself proof of delivery. This is not
/// the durable parser's per-item semantics. For `.intake`
/// endpoints the response is opaque and only the HTTP status code
/// matters.
///
/// Transport failures (HTTP errors, top-level bulk error responses) are
/// swallowed by design on the best-effort `ElasticLogger` path:
/// the logging path is sync and infallible, and a failed request
/// cannot propagate back to the caller. Subsequent payloads
/// continue to flow.
///
/// Lifetime: the consumer task is retained as a stored property.
/// `deinit` finishes the stream and requests cancellation so the
/// task can stop promptly after its current suspension point or
/// in-flight send returns.
final class DeliveryWorker: Sendable {
    /// Default upper bound on the number of pending payloads kept
    /// in the internal FIFO queue. Reaching this bound starts
    /// dropping new yields on the producer side.
    static let defaultQueueCapacity = 1000

    private let continuation: AsyncStream<Data>.Continuation
    private let task: Task<Void, Never>
    private let onBufferOverflow: (@Sendable () -> Void)?

    init(
        transport: any BulkTransport,
        endpoint: ElasticEndpoint,
        queueCapacity: Int = DeliveryWorker.defaultQueueCapacity,
        onBufferOverflow: (@Sendable () -> Void)? = nil
    ) {
        let (stream, continuation) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingOldest(queueCapacity)
        )
        self.continuation = continuation
        self.onBufferOverflow = onBufferOverflow

        let validatesBulkResponse: Bool = {
            if case .elasticsearch = endpoint { return true }
            return false
        }()

        task = Task.detached { [stream, transport, endpoint] in
            let url = endpoint.requestURL
            var headers = [
                "Content-Type": "application/x-ndjson"
            ]
            if let auth = endpoint.authorizationHeaderValue {
                headers["Authorization"] = auth
            }

            for await payload in stream {
                // Cancellation -- raised from `deinit` via
                // `task.cancel()` -- is a loop-termination signal,
                // not another transient delivery failure. Bail out
                // before doing any work for the current payload.
                if Task.isCancelled { break }
                let body = NDJSONBulkBody.make(document: payload)
                do {
                    let responseBody = try await transport.send(
                        url: url,
                        headers: headers,
                        body: body
                    )
                    if validatesBulkResponse {
                        try validateElasticBulkResponse(responseBody)
                    }
                } catch is CancellationError {
                    // The transport observed cancellation
                    // mid-flight. Same termination semantics as
                    // the pre-send check above.
                    break
                } catch {
                    // Best-effort `ElasticLogger` contract:
                    // swallow non-cancellation failures. The
                    // `ElasticLogger` path stays infallible by
                    // design; hosts that need durable delivery,
                    // retry, or per-failure diagnostics use
                    // `ElasticRemoteEngine` instead. If
                    // cancellation arrived between the throw and
                    // here, exit anyway so the loop does not race
                    // with `task.cancel()`.
                    if Task.isCancelled { break }
                }
            }
        }
    }

    /// Enqueues an ECS-encoded document for delivery.
    ///
    /// Synchronous and thread-safe. When the bounded buffer is at
    /// capacity the yield is rejected (drop-newest contract); the
    /// rejected document never reaches the transport. The rejection
    /// fires the worker's `onBufferOverflow` callback —
    /// ``ElasticLogger`` wires that callback to its
    /// ``ElasticLoggerDiagnostic/bufferOverflow`` signal so hosts
    /// can observe drop events without making `log` async or
    /// throwing.
    func enqueue(_ payload: Data) {
        let result = continuation.yield(payload)
        switch result {
        case .enqueued:
            break
        case .dropped:
            // `.bufferingOldest` rejected the yield because the
            // buffer is at capacity. Fire the observable signal so
            // the host can react (metric, secondary log channel)
            // without changing the synchronous infallible
            // `Logger.log` contract.
            onBufferOverflow?()
        case .terminated:
            // The stream was already finished (deinit raced the
            // yield). The payload is dropped; firing the overflow
            // signal at lifecycle teardown would be a false
            // positive, so do nothing.
            break
        @unknown default:
            // Future yield outcomes default to drop semantics from
            // the host's perspective: the payload did not reach
            // the transport.
            onBufferOverflow?()
        }
    }

    deinit {
        // Finish the stream so the consumer task's `for await` loop
        // exits cleanly, then request cooperative cancellation on
        // the retained task so it stops promptly after its current
        // suspension point or in-flight `transport.send` returns.
        continuation.finish()
        task.cancel()
    }
}
