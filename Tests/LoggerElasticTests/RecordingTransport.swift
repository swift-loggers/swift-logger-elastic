import Foundation

@testable import LoggerElastic

/// Test transport that captures every `send` call without touching
/// the network. Used by ``ElasticLoggerTests`` and
/// ``DeliveryWorkerTests`` to assert the URL, headers, and body
/// the production transport would have sent.
final class RecordingTransport: BulkTransport, @unchecked Sendable {
    struct Sent: Sendable {
        let url: URL
        let headers: [String: String]
        let body: Data
    }

    private let lock = NSLock()
    private var stored: [Sent] = []
    private var failNextRemaining: Int = 0
    private var defaultResponseBody: Data = .init()
    private var scriptedResponseBodies: [Data] = []

    /// A defensive snapshot of every successfully captured call.
    /// Failed sends are not recorded here; only the calls that
    /// returned successfully appear in this list. The returned
    /// array owns its own buffer.
    var sent: [Sent] {
        withLock { stored.map { $0 } }
    }

    /// Number of successfully captured sends. Cheap accessor for
    /// pollers (`waitForSendCount`) that would otherwise force a
    /// defensive copy of the entire `sent` array on every tick.
    var sentCount: Int {
        withLock { stored.count }
    }

    /// Schedules the next `count` sends to throw
    /// ``RecordingTransportError/simulated`` instead of recording.
    /// After `count` failures the transport returns to its normal
    /// recording behaviour and subsequent sends complete
    /// successfully.
    func failNext(_ count: Int) {
        withLock { failNextRemaining = count }
    }

    /// Sets the default response body returned by every successful
    /// future send when no scripted body is queued. Defaults to
    /// empty `Data`. Calling this clears any previously scripted
    /// queue.
    func setResponseBody(_ data: Data) {
        withLock {
            defaultResponseBody = data
            scriptedResponseBodies = []
        }
    }

    /// Scripts a deterministic queue of response bodies. The first
    /// successful send observes `bodies[0]`, the second observes
    /// `bodies[1]`, and so on. After the queue drains, subsequent
    /// sends fall back to whatever default body the test installed
    /// via `setResponseBody(_:)` (or the empty default). The queue
    /// is consumed under the lock per send, so the response a given
    /// send sees cannot race with a concurrent mutation by the test
    /// driver.
    func setResponseBodies(_ bodies: [Data]) {
        withLock {
            scriptedResponseBodies = bodies
        }
    }

    func send(
        url: URL,
        headers: [String: String],
        body: Data
    ) async throws -> Data {
        let result: SendOutcome = withLock {
            if failNextRemaining > 0 {
                failNextRemaining -= 1
                return .failure
            }
            stored.append(Sent(url: url, headers: headers, body: body))
            let responseBody: Data
            if !scriptedResponseBodies.isEmpty {
                responseBody = scriptedResponseBodies.removeFirst()
            } else {
                responseBody = defaultResponseBody
            }
            return .success(responseBody)
        }
        switch result {
        case .failure:
            throw RecordingTransportError.simulated
        case let .success(body):
            return body
        }
    }

    /// Locks `lock` for the duration of `body`. Hides the
    /// `NSLock.lock()` / `unlock()` calls behind a sync helper so
    /// async callers do not trip the Swift 6 strict-concurrency
    /// "unavailable from asynchronous contexts" rule.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private enum SendOutcome {
        case success(Data)
        case failure
    }
}

enum RecordingTransportError: Error, Sendable {
    case simulated
}

/// Polls `transport.sentCount` until it reaches `expected` or the
/// deadline elapses. Intended for tests that drive the asynchronous
/// `DeliveryWorker` from a synchronous test body. Reading the count
/// instead of `sent.count` avoids a defensive snapshot of the
/// entire captured-call array on every poll tick.
///
/// Cancellation is honoured explicitly: a cancelled task returns
/// immediately rather than continuing to poll, and a cancelled
/// `Task.sleep` exits the loop instead of being swallowed by a
/// `try?` that would let the surrounding `while` busy-spin until
/// the deadline.
func waitForSendCount(
    _ expected: Int,
    on transport: RecordingTransport,
    timeoutSeconds: TimeInterval = 2
) async {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while transport.sentCount < expected, Date() < deadline {
        if Task.isCancelled { return }
        do {
            try await Task.sleep(nanoseconds: 10_000_000)
        } catch {
            return
        }
    }
}

/// Test transport that captures sends like ``RecordingTransport``
/// but additionally suspends every send until the gate is opened.
/// Lets a test drive the bounded-queue overflow path: leave the
/// gate closed, enqueue more payloads than fit in the worker's
/// buffer, then open the gate and observe how many actually land
/// at the transport.
final class GatedTransport: BulkTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [RecordingTransport.Sent] = []
    private var open: Bool = false

    var sent: [RecordingTransport.Sent] {
        withLock { stored.map { $0 } }
    }

    /// Cheap counterpart to ``sent`` for pollers that only need
    /// the count, mirroring ``RecordingTransport/sentCount``.
    var sentCount: Int {
        withLock { stored.count }
    }

    func openGate() {
        withLock { open = true }
    }

    func send(
        url: URL,
        headers: [String: String],
        body: Data
    ) async throws -> Data {
        // Poll the gate so the consumer Task is parked here while
        // the producer fills the buffer. Polling beats wiring up a
        // continuation-based gate because Swift Testing's async
        // tests already use cooperative scheduling. Cancellation is
        // honoured explicitly: `Task.checkCancellation()` throws if
        // the surrounding task is already cancelled, and
        // `Task.sleep` throws on cancellation -- both propagate as
        // `CancellationError` to the worker's drain loop, which
        // treats it as a termination signal rather than a transient
        // failure.
        while !isOpen {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        withLock {
            stored.append(RecordingTransport.Sent(url: url, headers: headers, body: body))
        }
        return Data()
    }

    private var isOpen: Bool {
        withLock { open }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
