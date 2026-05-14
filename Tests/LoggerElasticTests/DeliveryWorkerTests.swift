import Foundation
import Testing

@testable import LoggerElastic

@Suite("DeliveryWorker")
struct DeliveryWorkerTests {
    // MARK: Direct mode request shape

    @Test("Direct endpoint produces a POST to <url>/_bulk with ApiKey auth")
    func directEndpointRequestShape() async throws {
        let cluster = try #require(URL(string: "https://es.example.com"))
        let transport = RecordingTransport()
        let worker = DeliveryWorker(
            transport: transport,
            endpoint: .elasticsearch(url: cluster, apiKey: "abc123")
        )

        let document = Data(#"{"hello":"world"}"#.utf8)
        worker.enqueue(document)
        await waitForSendCount(1, on: transport)

        try #require(transport.sent.count == 1)
        let call = transport.sent[0]

        #expect(call.url.absoluteString == "https://es.example.com/_bulk")
        #expect(call.headers["Content-Type"] == "application/x-ndjson")
        #expect(call.headers["Authorization"] == "ApiKey abc123")

        let raw = try #require(String(data: call.body, encoding: .utf8))
        let expected = """
        {"create":{"_index":"logs-swift-loggers-default"}}
        {"hello":"world"}

        """
        #expect(raw == expected)
    }

    // MARK: Intake mode request shape

    @Test("Intake endpoint POSTs to the URL verbatim with the configured Authorization header")
    func intakeEndpointRequestShape() async throws {
        let intake = try #require(URL(string: "https://logs.example.com/elastic"))
        let transport = RecordingTransport()
        let worker = DeliveryWorker(
            transport: transport,
            endpoint: .intake(url: intake, authorizationHeader: "Bearer xyz")
        )

        worker.enqueue(Data(#"{"k":1}"#.utf8))
        await waitForSendCount(1, on: transport)

        try #require(transport.sent.count == 1)
        let call = transport.sent[0]

        #expect(call.url == intake)
        #expect(call.headers["Content-Type"] == "application/x-ndjson")
        #expect(call.headers["Authorization"] == "Bearer xyz")

        // Body shape is the same NDJSON `_bulk` framing used by
        // the direct endpoint: action line, newline, document,
        // newline. Pinning this prevents an intake-only encoding
        // path from ever silently diverging from the direct path.
        let raw = try #require(String(data: call.body, encoding: .utf8))
        let expected = """
        {"create":{"_index":"logs-swift-loggers-default"}}
        {"k":1}

        """
        #expect(raw == expected)
    }

    @Test("Intake endpoint with nil authorization omits the Authorization header")
    func intakeNilAuthOmitsHeader() async throws {
        let intake = try #require(URL(string: "https://logs.example.com/elastic"))
        let transport = RecordingTransport()
        let worker = DeliveryWorker(
            transport: transport,
            endpoint: .intake(url: intake, authorizationHeader: nil)
        )

        worker.enqueue(Data("{}".utf8))
        await waitForSendCount(1, on: transport)

        try #require(transport.sent.count == 1)
        let call = transport.sent[0]
        #expect(call.headers["Content-Type"] == "application/x-ndjson")
        #expect(call.headers["Authorization"] == nil)
    }

    // MARK: FIFO ordering

    @Test("Enqueued payloads reach the transport in arrival order")
    func fifoOrderPreserved() async throws {
        let cluster = try #require(URL(string: "https://es.example.com"))
        let transport = RecordingTransport()
        let worker = DeliveryWorker(
            transport: transport,
            endpoint: .elasticsearch(url: cluster, apiKey: "k")
        )

        let count = 50
        for index in 0 ..< count {
            worker.enqueue(Data("doc-\(index)".utf8))
        }
        await waitForSendCount(count, on: transport)

        try #require(transport.sent.count == count)
        for index in 0 ..< count {
            // Compare the document line as exact bytes so a
            // substring match (`doc-1` matches `doc-10`) cannot
            // mask a reorder regression.
            let document = try ecsDocumentLine(from: transport.sent[index].body)
            #expect(document == Data("doc-\(index)".utf8))
        }
    }

    // MARK: Failure isolation

    @Test("Transport failure does not block subsequent payloads")
    func transportFailureDoesNotBlockLaterPayloads() async throws {
        let cluster = try #require(URL(string: "https://es.example.com"))
        let transport = RecordingTransport()
        let worker = DeliveryWorker(
            transport: transport,
            endpoint: .elasticsearch(url: cluster, apiKey: "k")
        )

        // Fail just the first send. The second send must succeed
        // and reach the recorder, proving the worker keeps
        // draining after a swallowed failure.
        transport.failNext(1)
        worker.enqueue(Data("first".utf8))
        worker.enqueue(Data("second".utf8))

        await waitForSendCount(1, on: transport)
        try #require(transport.sent.count == 1)
        let document = try ecsDocumentLine(from: transport.sent[0].body)
        #expect(document == Data("second".utf8))
    }

    // MARK: Bulk response validation

    @Test("Direct endpoint swallows top-level _bulk error responses without blocking later payloads")
    func directEndpointHandlesTopLevelBulkErrorResponses() async throws {
        let cluster = try #require(URL(string: "https://es.example.com"))
        let transport = RecordingTransport()
        // Script the response queue so the first send observes a
        // top-level `errors:true` bulk response and the second
        // observes a clean success body. The queue is consumed
        // under the lock per send, so the assertion does not race
        // with the worker's async drain.
        transport.setResponseBodies([
            Data(#"{"took":3,"errors":true,"items":[{"create":{"status":400}}]}"#.utf8),
            Data(#"{"took":2,"errors":false,"items":[{"create":{"status":201}}]}"#.utf8)
        ])
        let worker = DeliveryWorker(
            transport: transport,
            endpoint: .elasticsearch(url: cluster, apiKey: "k")
        )

        worker.enqueue(Data("first".utf8))
        worker.enqueue(Data("second".utf8))

        await waitForSendCount(2, on: transport)
        try #require(transport.sent.count == 2)
        let firstDoc = try ecsDocumentLine(from: transport.sent[0].body)
        let secondDoc = try ecsDocumentLine(from: transport.sent[1].body)
        #expect(firstDoc == Data("first".utf8))
        #expect(secondDoc == Data("second".utf8))
    }

    @Test("Intake endpoint accepts opaque 2xx response bodies without bulk validation")
    func intakeEndpointAcceptsOpaqueResponse() async throws {
        let intake = try #require(URL(string: "https://logs.example.com"))
        let transport = RecordingTransport()
        // Response body that would trip the bulk validator if it
        // ran. The intake mode must not run it, so the send is
        // recorded as a success.
        transport.setResponseBody(
            Data(#"{"errors":true,"items":[]}"#.utf8)
        )
        let worker = DeliveryWorker(
            transport: transport,
            endpoint: .intake(url: intake, authorizationHeader: nil)
        )

        worker.enqueue(Data("payload".utf8))
        await waitForSendCount(1, on: transport)

        try #require(transport.sent.count == 1)
        let document = try ecsDocumentLine(from: transport.sent[0].body)
        #expect(document == Data("payload".utf8))
    }

    // MARK: Bounded queue

    @Test("Bounded queue keeps the oldest payloads and drops new yields when full")
    func boundedQueueKeepsOldestAndDropsNewest() async throws {
        let cluster = try #require(URL(string: "https://es.example.com"))
        let transport = GatedTransport()
        let queueCapacity = 2
        let worker = DeliveryWorker(
            transport: transport,
            endpoint: .elasticsearch(url: cluster, apiKey: "k"),
            queueCapacity: queueCapacity
        )

        // Yield more than the queue can hold. The consumer Task
        // has started and immediately pulls the first payload, but
        // it blocks on the gated transport, so further yields fill
        // the bounded buffer to `queueCapacity` and any beyond are
        // dropped on the producer side.
        let total = queueCapacity * 5
        for index in 0 ..< total {
            worker.enqueue(Data("doc-\(index)".utf8))
        }

        // Open the gate and let the worker drain whatever survived
        // the buffer. The expected ceiling is `queueCapacity + 1`:
        // one in-flight payload that the consumer pulled before
        // blocking, plus the `queueCapacity` payloads still in the
        // bounded buffer.
        let expectedCeiling = queueCapacity + 1
        transport.openGate()

        // Cancellation is honoured explicitly: a cancelled task
        // exits the loop instead of busy-spinning until the
        // deadline, mirroring `waitForSendCount` and
        // `GatedTransport.send`.
        let deadline = Date().addingTimeInterval(2)
        while transport.sentCount < expectedCeiling, Date() < deadline {
            if Task.isCancelled { break }
            do {
                try await Task.sleep(nanoseconds: 10_000_000)
            } catch {
                break
            }
        }

        // Sanity: at least one payload must have made it through,
        // and we must not have somehow delivered all of them.
        let survivors = transport.sent
        #expect(survivors.count <= expectedCeiling)
        #expect(survivors.count >= 1)
        #expect(survivors.count < total)

        // Drop-newest contract: the survivors are the *oldest*
        // payloads. With `bufferingOldest(queueCapacity)`, the
        // buffer retains entries that arrived earliest and drops
        // every later yield once the buffer is at capacity, so the
        // survivors must be `doc-0, doc-1, ..., doc-(survivors.count - 1)`
        // in arrival order. A `bufferingNewest` (or any other)
        // policy would surface here as a different prefix.
        for index in 0 ..< survivors.count {
            let document = try ecsDocumentLine(from: survivors[index].body)
            #expect(document == Data("doc-\(index)".utf8))
        }
    }
}
