import Foundation
import LoggerRemote
import Testing

@testable import LoggerElastic

// swiftlint:disable type_body_length
// Reason: LOCKED batch-round transport contract test IDs (per-item
// dispatch, whole-batch failures, indexName injection safety,
// stateless adapter, action propagation) kept in one struct so the
// 0.1.0 migration validation stays cohesive and auditable.

/// Coverage for ``ElasticRemoteTransport`` as a `RemoteTransport`
/// conformer.
///
/// The suite drives the adapter through the seam-injected
/// ``RecordingTransport`` so each test fully scripts the HTTP
/// response (or the absence of one) and asserts the per-item
/// `Result` projection plus the engine-facing ``classify(_:)``
/// mapping. None of the tests touch the network.
@Suite("ElasticRemoteTransport batch dispatch")
struct ElasticRemoteTransportTests {
    private static func makeDirectAdapter(
        transport: RecordingTransport
    ) throws -> ElasticRemoteTransport {
        let url = try #require(URL(string: "https://example.test/cluster"))
        return ElasticRemoteTransport(
            endpoint: .elasticsearch(url: url, apiKey: "test-key"),
            indexName: "logs-elastic-remote-test",
            transport: transport
        )
    }

    private static func makeIntakeAdapter(
        transport: RecordingTransport
    ) throws -> ElasticRemoteTransport {
        let url = try #require(URL(string: "https://example.test/intake"))
        return ElasticRemoteTransport(
            endpoint: .intake(
                url: url,
                authorizationHeader: "Bearer test"
            ),
            indexName: "logs-elastic-remote-test",
            transport: transport
        )
    }

    private static func batchItem(_ payload: String) -> RemoteTransportBatchItem {
        RemoteTransportBatchItem(payloadBytes: Data(payload.utf8))
    }

    private static func bulkResponseBody(itemStatuses: [Int]) throws -> Data {
        let hasErrors = itemStatuses.contains { !(200 ..< 300).contains($0) }
        let items = itemStatuses.map { status -> [String: Any] in
            var actionFields: [String: Any] = [
                "_index": "logs-elastic-remote-test",
                "status": status
            ]
            if !(200 ..< 300).contains(status) {
                actionFields["error"] = ["type": "test_error_for_status_\(status)"]
            }
            return ["create": actionFields]
        }
        let envelope: [String: Any] = [
            "took": 1,
            "errors": hasErrors,
            "items": items
        ]
        return try JSONSerialization.data(withJSONObject: envelope)
    }

    @Test("all-item success: every per-input Result is .success(_)")
    func allItemSuccess() async throws {
        let recorder = RecordingTransport()
        recorder.setResponseBody(try Self.bulkResponseBody(itemStatuses: [201, 201, 201]))
        let adapter = try Self.makeDirectAdapter(transport: recorder)
        let items = [
            Self.batchItem("doc-1"),
            Self.batchItem("doc-2"),
            Self.batchItem("doc-3")
        ]

        let results = try await adapter.sendBatch(items)

        #expect(results.count == items.count)
        for result in results {
            switch result {
            case .success:
                break
            case .failure:
                Issue.record("expected .success for accepted item")
            }
        }
        let classifications = await withTaskGroup(of: RemoteDeliveryResult.self) { group in
            for result in results {
                group.addTask { await adapter.classify(result) }
            }
            var collected: [RemoteDeliveryResult] = []
            for await classification in group { collected.append(classification) }
            return collected
        }
        #expect(classifications.allSatisfy { $0 == .success })
    }

    @Test("partial success: per-item retryable stays retryable, sibling items unaffected")
    func partialSuccessWithRetryableItem() async throws {
        let recorder = RecordingTransport()
        // statuses: success, retryable (429), success
        recorder.setResponseBody(try Self.bulkResponseBody(itemStatuses: [201, 429, 201]))
        let adapter = try Self.makeDirectAdapter(transport: recorder)
        let items = (1 ... 3).map { Self.batchItem("doc-\($0)") }

        let results = try await adapter.sendBatch(items)

        #expect(results.count == 3)
        switch results[0] {
        case .success: break
        case .failure: Issue.record("results[0] should be .success")
        }
        switch results[1] {
        case .success:
            Issue.record("results[1] should be .failure(.retryable)")
        case let .failure(error):
            guard let failure = error as? ElasticItemFailure else {
                Issue.record("results[1] error type mismatch")
                return
            }
            switch failure {
            case let .retryable(action, status, _):
                #expect(action == .create)
                #expect(status == 429)
            case .terminal:
                Issue.record("results[1] should be retryable not terminal")
            }
        }
        switch results[2] {
        case .success: break
        case .failure: Issue.record("results[2] should be .success")
        }

        // Engine-facing classification — retryable item stays
        // retryable, sibling items resolve.
        #expect(await adapter.classify(results[0]) == .success)
        #expect(await adapter.classify(results[1])
            == .retryable(reason: .transportRejected))
        #expect(await adapter.classify(results[2]) == .success)
    }

    @Test("permanent item failure: status 400 maps to .terminal")
    func permanentItemFailure() async throws {
        let recorder = RecordingTransport()
        recorder.setResponseBody(try Self.bulkResponseBody(itemStatuses: [400]))
        let adapter = try Self.makeDirectAdapter(transport: recorder)
        let items = [Self.batchItem("bad-doc")]

        let results = try await adapter.sendBatch(items)

        #expect(results.count == 1)
        switch results[0] {
        case .success:
            Issue.record("expected .failure(.terminal) for status 400")
        case let .failure(error):
            guard let failure = error as? ElasticItemFailure else {
                Issue.record("error type mismatch")
                return
            }
            switch failure {
            case let .terminal(action, status, errorType):
                #expect(action == .create)
                #expect(status == 400)
                #expect(errorType == "test_error_for_status_400")
            case .retryable:
                Issue.record("status 400 should be terminal")
            }
        }
        #expect(
            await adapter.classify(results[0])
                == .terminal(reason: .transportRejected)
        )
    }

    @Test("whole HTTP failure: sendBatch throws; classify routes every item to retryable")
    func wholeHTTPFailureClassifiesRetryable() async throws {
        let recorder = RecordingTransport()
        recorder.failNext(1)
        let adapter = try Self.makeDirectAdapter(transport: recorder)
        let items = [
            Self.batchItem("doc-1"),
            Self.batchItem("doc-2")
        ]

        await #expect(throws: RecordingTransportError.simulated) {
            _ = try await adapter.sendBatch(items)
        }
        // The engine routes a `sendBatch` throw through
        // `classify(_:)` with the same `.failure(error)` per active
        // item in the round. Mirror that loop here and assert one
        // `.retryable` per input item so the test title's "routes
        // every item" claim has matching coverage.
        var classifications: [RemoteDeliveryResult] = []
        for _ in items {
            let result = await adapter.classify(
                .failure(RecordingTransportError.simulated)
            )
            classifications.append(result)
        }
        #expect(classifications == [
            .retryable(reason: .transportRejected),
            .retryable(reason: .transportRejected)
        ])
    }

    @Test("HTTP 401 (permanent 4xx) whole-batch failure classifies as terminal")
    func http401PermanentWholeBatchTerminal() async throws {
        // Pinned to `401` so the test exercises the permanent-4xx
        // branch (auth / URL bug — retrying with the same
        // credentials will not help) rather than the whole `400..<500`
        // range. The transient 4xx neighbours `408` and `429` have
        // their own retryable tests and are NOT in scope here.
        let adapter = try Self.makeDirectAdapter(transport: RecordingTransport())
        let classification = await adapter.classify(
            .failure(BulkTransportError.unsuccessfulStatus(401))
        )
        #expect(classification == .terminal(reason: .transportRejected))
    }

    @Test("HTTP 408 whole-batch failure classifies as retryable")
    func http408WholeBatchRetryable() async throws {
        let adapter = try Self.makeDirectAdapter(transport: RecordingTransport())
        let classification = await adapter.classify(
            .failure(BulkTransportError.unsuccessfulStatus(408))
        )
        #expect(classification == .retryable(reason: .transportRejected))
    }

    @Test("HTTP 5xx whole-batch failure classifies as retryable")
    func http5xxWholeBatchRetryable() async throws {
        let adapter = try Self.makeDirectAdapter(transport: RecordingTransport())
        let classification = await adapter.classify(
            .failure(BulkTransportError.unsuccessfulStatus(503))
        )
        #expect(classification == .retryable(reason: .transportRejected))
    }

    @Test("response item count mismatch: sendBatch throws, classify maps to retryable")
    func responseItemCountMismatch() async throws {
        let recorder = RecordingTransport()
        // 3 input items, response carries only 2.
        recorder.setResponseBody(try Self.bulkResponseBody(itemStatuses: [201, 201]))
        let adapter = try Self.makeDirectAdapter(transport: recorder)
        let items = (1 ... 3).map { Self.batchItem("doc-\($0)") }

        do {
            _ = try await adapter.sendBatch(items)
            Issue.record("expected throw for count mismatch")
        } catch let bulkError as ElasticBulkError {
            switch bulkError {
            case let .responseItemCountMismatch(expected, actual):
                #expect(expected == 3)
                #expect(actual == 2)
            default:
                Issue.record("expected .responseItemCountMismatch")
            }
        } catch {
            Issue.record("expected ElasticBulkError, got \(error)")
        }
        let classification = await adapter.classify(
            .failure(ElasticBulkError.responseItemCountMismatch(expected: 3, actual: 2))
        )
        #expect(classification == .retryable(reason: .transportRejected))
    }

    @Test("non-JSON bulk response: sendBatch throws .invalidBulkResponseJSON")
    func nonJSONBulkResponseThrows() async throws {
        let recorder = RecordingTransport()
        recorder.setResponseBody(Data("{not json".utf8))
        let adapter = try Self.makeDirectAdapter(transport: recorder)
        let items = [Self.batchItem("doc-1")]

        do {
            _ = try await adapter.sendBatch(items)
            Issue.record("expected throw for non-JSON response")
        } catch let bulkError as ElasticBulkError {
            #expect(bulkError == .invalidBulkResponseJSON)
        } catch {
            Issue.record("expected ElasticBulkError.invalidBulkResponseJSON, got \(error)")
        }
    }

    @Test("returned result array preserves input order across mixed item statuses")
    func resultArrayPreservesInputOrder() async throws {
        let recorder = RecordingTransport()
        // Mixed statuses laid out in positions 0..4 of the request.
        // Per-input ordering is positional: returned Result at index
        // `i` corresponds to items[i].
        let statuses = [201, 400, 429, 201, 503]
        recorder.setResponseBody(try Self.bulkResponseBody(itemStatuses: statuses))
        let adapter = try Self.makeDirectAdapter(transport: recorder)
        let items = (0 ..< 5).map { Self.batchItem("doc-\($0)") }

        let results = try await adapter.sendBatch(items)

        #expect(results.count == 5)
        for (index, expectedStatus) in statuses.enumerated() {
            switch results[index] {
            case .success:
                // Adapter contract: only `200` / `201` are projected
                // as per-item `.success`; anything else (including
                // unrecognized 2xx codes) lands in the `.failure`
                // branch below.
                #expect(
                    ElasticBulkItemClassification.classify(status: expectedStatus)
                        == .success
                )
            case let .failure(error):
                guard let failure = error as? ElasticItemFailure else {
                    Issue.record("results[\(index)] error type mismatch")
                    continue
                }
                switch failure {
                case let .retryable(action, status, _),
                     let .terminal(action, status, _):
                    #expect(action == .create)
                    #expect(status == expectedStatus)
                }
            }
        }
    }

    @Test("intake endpoint: opaque 2xx body succeeds every input item")
    func intakeEndpointSucceedsOpaque() async throws {
        let recorder = RecordingTransport()
        recorder.setResponseBody(Data("opaque-intake-response".utf8))
        let adapter = try Self.makeIntakeAdapter(transport: recorder)
        let items = (1 ... 4).map { Self.batchItem("doc-\($0)") }

        let results = try await adapter.sendBatch(items)

        #expect(results.count == items.count)
        for result in results {
            switch result {
            case let .success(response):
                // Adapter passes the intake body through verbatim
                // so consumers that inspect it can do so.
                #expect(response.responseBytes == Data("opaque-intake-response".utf8))
            case .failure:
                Issue.record("intake endpoint should treat 2xx as success per item")
            }
        }
    }

    @Test("adapter is stateless: no durable queue, no retry loop, no in-process buffer")
    func adapterIsStateless() async throws {
        // Two back-to-back `sendBatch` calls; the adapter must not
        // retain any item state across calls. A `sendBatch` returning
        // .retryable for an item is the engine's signal to dispatch
        // that item again on the next round — the adapter never
        // re-dispatches on its own.
        let recorder = RecordingTransport()
        recorder.setResponseBodies([
            try Self.bulkResponseBody(itemStatuses: [429]),
            try Self.bulkResponseBody(itemStatuses: [201])
        ])
        let adapter = try Self.makeDirectAdapter(transport: recorder)
        let payload = Self.batchItem("retry-me")

        let firstResults = try await adapter.sendBatch([payload])
        #expect(firstResults.count == 1)
        switch firstResults[0] {
        case .failure:
            break
        case .success:
            Issue.record("expected first call to surface 429 as failure")
        }

        // No adapter-side retry: the only way a second wire request
        // happens is if the engine (or the test) calls `sendBatch`
        // again. Verify by counting transport sends across the gap.
        #expect(recorder.sentCount == 1)

        // Second engine-driven dispatch — the adapter rebuilds the
        // wire payload from the new input, never from cached state.
        let secondResults = try await adapter.sendBatch([payload])
        #expect(secondResults.count == 1)
        switch secondResults[0] {
        case .success: break
        case .failure: Issue.record("expected second call to surface 201 as success")
        }
        #expect(recorder.sentCount == 2)
    }

    @Test("status 409 _bulk create conflict locks to .terminal")
    func conflict409LocksToTerminal() async throws {
        let recorder = RecordingTransport()
        recorder.setResponseBody(try Self.bulkResponseBody(itemStatuses: [409]))
        let adapter = try Self.makeDirectAdapter(transport: recorder)
        let items = [Self.batchItem("dup-doc")]

        let results = try await adapter.sendBatch(items)

        #expect(results.count == 1)
        switch results[0] {
        case .success:
            Issue.record("409 must surface as .failure(.terminal), not success")
        case let .failure(error):
            guard let failure = error as? ElasticItemFailure else {
                Issue.record("409 error type mismatch")
                return
            }
            switch failure {
            case let .terminal(action, status, errorType):
                #expect(action == .create)
                #expect(status == 409)
                #expect(errorType == "test_error_for_status_409")
            case .retryable:
                Issue.record("409 must lock to .terminal, never .retryable")
            }
        }
        #expect(
            await adapter.classify(results[0])
                == .terminal(reason: .transportRejected)
        )
    }

    @Test("unrecognized 2xx item status (e.g. 202) classifies as .terminal, not .success")
    func unrecognized2xxItemTerminal() async throws {
        let recorder = RecordingTransport()
        // `bulkResponseBody` writes `errors: false` for 202 because
        // the helper treats `200..<300` as the envelope's
        // hasErrors window. The adapter classifier must still
        // refuse to read 202 as a per-item success — `errors: false`
        // is not the delivery decision; per-item status drives it.
        recorder.setResponseBody(try Self.bulkResponseBody(itemStatuses: [202]))
        let adapter = try Self.makeDirectAdapter(transport: recorder)
        let items = [Self.batchItem("doc-1")]

        let results = try await adapter.sendBatch(items)

        #expect(results.count == 1)
        switch results[0] {
        case .success:
            Issue.record("202 must not be projected as per-item success")
        case let .failure(error):
            guard let failure = error as? ElasticItemFailure else {
                Issue.record("202 error type mismatch")
                return
            }
            switch failure {
            case let .terminal(action, status, _):
                #expect(action == .create)
                #expect(status == 202)
            case .retryable:
                Issue.record("202 must classify as .terminal, never .retryable")
            }
        }
        #expect(
            await adapter.classify(results[0])
                == .terminal(reason: .transportRejected)
        )
    }

    @Test("HTTP 429 whole-batch failure classifies as retryable (backpressure)")
    func http429WholeBatchRetryable() async throws {
        let adapter = try Self.makeDirectAdapter(transport: RecordingTransport())
        let classification = await adapter.classify(
            .failure(BulkTransportError.unsuccessfulStatus(429))
        )
        #expect(classification == .retryable(reason: .transportRejected))
    }

    @Test("indexName with quote / backslash / newline stays JSON-safe in the action line")
    func indexNameJSONInjection() async throws {
        let recorder = RecordingTransport()
        recorder.setResponseBody(try Self.bulkResponseBody(itemStatuses: [201]))
        let directURL = try #require(URL(string: "https://example.test/cluster"))
        // Explicit character build so the literal stays unambiguous:
        // `weird-` + quote + backslash + `n` + newline + `logs`.
        // The quote would close a JSON string built by naive
        // interpolation, the backslash would escape a JSON
        // closing brace, and the newline would split the action
        // line away from the document line in NDJSON framing.
        let hostileIndexName = "weird-\"\\n\nlogs"
        let adapter = ElasticRemoteTransport(
            endpoint: .elasticsearch(url: directURL, apiKey: "test-key"),
            indexName: hostileIndexName,
            transport: recorder
        )
        let items = [Self.batchItem("doc-1")]

        _ = try await adapter.sendBatch(items)

        // The wire body must frame as well-formed NDJSON: action
        // line + document line, each independently JSON-decodable
        // for the action half. The embedded newline inside
        // `indexName` MUST stay quoted inside the JSON action line
        // so the byte-level newline that splits NDJSON records is
        // unambiguous.
        let sent = recorder.sent
        try #require(sent.count == 1)
        let body = sent[0].body
        // `_bulk` NDJSON framing terminates the body with `0x0A`;
        // `split(omittingEmptySubsequences: true)` below would
        // otherwise silently accept a body missing the trailing
        // newline.
        #expect(body.last == 0x0A)
        let lines = body.split(separator: 0x0A, omittingEmptySubsequences: true)
        try #require(lines.count == 2)
        let actionLine = Data(lines[0])
        let parsed = try JSONSerialization.jsonObject(with: actionLine)
        let actionObject = try #require(parsed as? [String: Any])
        let createFields = try #require(actionObject["create"] as? [String: Any])
        let parsedIndex = try #require(createFields["_index"] as? String)
        #expect(parsedIndex == hostileIndexName)
        // The document line MUST be the input payload bytes verbatim:
        // hostile escaping in `indexName` is confined to the action
        // line and cannot bleed into the document framing.
        #expect(Data(lines[1]) == Data("doc-1".utf8))
    }
}

// swiftlint:enable type_body_length
