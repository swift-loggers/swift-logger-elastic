import Foundation
import LoggerRemote
import Testing

@testable import LoggerElastic

/// End-to-end integration coverage for the M3.5 Elastic ↔
/// `swift-logger-remote` wiring.
///
/// Each test stands up an isolated temp queue + export directory,
/// builds the engine through ``ElasticRemoteEngine/make(_:bulkTransport:)``
/// with a scripted HTTP seam, runs the public enqueue / flush
/// lifecycle, and asserts the engine-facing `RemoteFlushSummary`
/// outcome. The HTTP layer is replaced by a recorder so the test is
/// deterministic and network-free, but the engine path itself — the
/// durable queue, batch-round dispatch, per-item classification, and
/// acknowledgement-to-removal lifecycle — is fully real.
@Suite("ElasticRemoteEngine integration")
struct ElasticRemoteEngineIntegrationTests {
    private static func uniqueDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LoggerElasticIntegrationTests")
            .appendingPathComponent(UUID().uuidString)
    }

    private static func cleanup(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func makeConfiguration(
        queueDirectory: URL,
        exportDirectory: URL
    ) throws -> ElasticRemoteEngine.Configuration {
        let directURL = try #require(URL(string: "https://example.test/cluster"))
        let batchPolicy = try RemoteBatchPolicy.make(
            maxEntryCount: 100,
            maxByteCount: 64 * 1024
        )
        let retryPolicy = try RemoteRetryPolicy.make(
            maxAttempts: 2,
            backoff: .exponential(
                initialSeconds: 0.01, multiplier: 2, capSeconds: 0.05
            )
        )
        return ElasticRemoteEngine.Configuration(
            endpoint: .elasticsearch(url: directURL, apiKey: "test-key"),
            indexName: "logs-elastic-integration-test",
            queueDirectory: queueDirectory,
            exportDirectory: exportDirectory,
            batchPolicy: batchPolicy,
            retryPolicy: retryPolicy
        )
    }

    /// Counts the per-item entries inside every captured `_bulk`
    /// request body in `sends`. The NDJSON `_bulk` framing is one
    /// action line per item followed by exactly one document line
    /// per item, each terminated by `0x0A`; the item count is the
    /// line count divided by two. Used by the active-set shrink
    /// proof to assert per-round dispatch shape (e.g. `[3, 1]`
    /// means round 1 dispatched 3 items, round 2 dispatched the
    /// 1 retryable subset).
    private static func bulkRequestItemCounts(
        _ sends: [RecordingTransport.Sent]
    ) throws -> [Int] {
        try sends.map { sent in
            // NDJSON `_bulk` framing terminates every line with
            // `0x0A`, including the last document; a body without a
            // trailing newline would otherwise pass `split` with
            // `omittingEmptySubsequences: true` silently.
            guard sent.body.last == 0x0A else {
                throw IntegrationTestError.malformedBulkRequestBody
            }
            let lineCount = sent.body
                .split(separator: 0x0A, omittingEmptySubsequences: true)
                .count
            guard lineCount.isMultiple(of: 2) else {
                throw IntegrationTestError.malformedBulkRequestBody
            }
            return lineCount / 2
        }
    }

    private enum IntegrationTestError: Error, Equatable {
        case malformedBulkRequestBody
    }

    private static func bulkResponseBody(itemStatuses: [Int]) throws -> Data {
        let hasErrors = itemStatuses.contains { !(200 ..< 300).contains($0) }
        let items = itemStatuses.map { status -> [String: Any] in
            var actionFields: [String: Any] = [
                "_index": "logs-elastic-integration-test",
                "status": status
            ]
            if !(200 ..< 300).contains(status) {
                actionFields["error"] = ["type": "test_error_for_\(status)"]
            }
            return ["create": actionFields]
        }
        let envelope: [String: Any] = [
            "took": 1, "errors": hasErrors, "items": items
        ]
        return try JSONSerialization.data(withJSONObject: envelope)
    }

    @Test("enqueue + flush: all items accepted by _bulk → ACK removes delivered bytes")
    func flushAllAcceptedAcknowledges() async throws {
        let queueDir = Self.uniqueDirectory()
        let exportDir = Self.uniqueDirectory()
        defer {
            Self.cleanup(queueDir)
            Self.cleanup(exportDir)
        }
        try FileManager.default.createDirectory(
            at: queueDir, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: exportDir, withIntermediateDirectories: true
        )

        let recorder = RecordingTransport()
        recorder.setResponseBody(try Self.bulkResponseBody(itemStatuses: [201, 201, 201]))
        let configuration = try Self.makeConfiguration(
            queueDirectory: queueDir, exportDirectory: exportDir
        )
        let wiring = ElasticRemoteEngine.make(configuration, bulkTransport: recorder)

        for index in 1 ... 3 {
            try await wiring.queue.enqueue(RemoteDeliveryEntry(
                identifier: UInt64(index),
                payload: Data(#"{"message":"doc-\#(index)"}"#.utf8)
            ))
        }

        let summary = try await wiring.engine.flush()
        #expect(summary.attemptedBatches == 1)
        #expect(summary.succeededEntries == 3)
        #expect(summary.terminalEntries == 0)
        #expect(summary.retryableEntries == 0)
        #expect(summary.acknowledgement == .removedDeliveredBytes)
        #expect(recorder.sentCount == 1)

        // Follow-up flush: after `.removedDeliveredBytes` the
        // persistence layer has dropped the delivered queue payload
        // bytes, so the next `flush()` finds the queue empty.
        // No batch is attempted, no bulk call is made; the engine
        // releases the empty boundary.
        let second = try await wiring.engine.flush()
        #expect(second.attemptedBatches == 0)
        #expect(second.acknowledgement == .emptyReleased)
        #expect(recorder.sentCount == 1)
    }

    @Test("enqueue + flush: terminal-only items still ACK (pass-wide resolution rule)")
    func flushTerminalItemsAcknowledges() async throws {
        let queueDir = Self.uniqueDirectory()
        let exportDir = Self.uniqueDirectory()
        defer {
            Self.cleanup(queueDir)
            Self.cleanup(exportDir)
        }
        try FileManager.default.createDirectory(
            at: queueDir, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: exportDir, withIntermediateDirectories: true
        )

        let recorder = RecordingTransport()
        // All three items permanently rejected (400 schema). The
        // remote engine's ACK rule is pass-wide: every recovered
        // entry is `.terminal` (resolved) → ack fires.
        recorder.setResponseBodies([
            try Self.bulkResponseBody(itemStatuses: [400, 400, 400])
        ])
        let configuration = try Self.makeConfiguration(
            queueDirectory: queueDir, exportDirectory: exportDir
        )
        let wiring = ElasticRemoteEngine.make(configuration, bulkTransport: recorder)

        for index in 1 ... 3 {
            try await wiring.queue.enqueue(RemoteDeliveryEntry(
                identifier: UInt64(index),
                payload: Data(#"{"bad":"doc-\#(index)"}"#.utf8)
            ))
        }

        let summary = try await wiring.engine.flush()
        #expect(summary.succeededEntries == 0)
        #expect(summary.terminalEntries == 3)
        #expect(summary.retryableEntries == 0)
        #expect(summary.acknowledgement == .removedDeliveredBytes)
        #expect(recorder.sentCount == 1)

        // Follow-up flush: a fully-resolved terminal pass still
        // acknowledges (pass-wide resolution rule), so persistence
        // has dropped the delivered queue payload bytes and the
        // next `flush()` is an empty release without any bulk call.
        let second = try await wiring.engine.flush()
        #expect(second.attemptedBatches == 0)
        #expect(second.acknowledgement == .emptyReleased)
        #expect(recorder.sentCount == 1)
    }

    @Test("retryable item exhausts budget across rounds; non-ACK keeps outstanding boundary")
    func flushRetryableExhaustsBudgetNoAck() async throws {
        let queueDir = Self.uniqueDirectory()
        let exportDir = Self.uniqueDirectory()
        defer {
            Self.cleanup(queueDir)
            Self.cleanup(exportDir)
        }
        try FileManager.default.createDirectory(
            at: queueDir, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: exportDir, withIntermediateDirectories: true
        )

        let recorder = RecordingTransport()
        // First flush: one retryable item exhausts the in-pass budget, so the engine
        // does not acknowledge and the retained export artifact stays available.
        // Follow-up flush: the engine reparses the full retained export artifact;
        // there is no cross-flush per-entry retry memory.
        recorder.setResponseBodies([
            try Self.bulkResponseBody(itemStatuses: [201, 429, 201]),
            try Self.bulkResponseBody(itemStatuses: [429]),
            try Self.bulkResponseBody(itemStatuses: [201, 201, 201])
        ])
        let configuration = try Self.makeConfiguration(
            queueDirectory: queueDir, exportDirectory: exportDir
        )
        let wiring = ElasticRemoteEngine.make(configuration, bulkTransport: recorder)

        for index in 1 ... 3 {
            try await wiring.queue.enqueue(RemoteDeliveryEntry(
                identifier: UInt64(index),
                payload: Data(#"{"message":"doc-\#(index)"}"#.utf8)
            ))
        }

        let summary = try await wiring.engine.flush()
        // `attemptedBatches` counts drained export batches, not transport retry rounds;
        // this flush performs two `sendBatch` rounds over one drained export batch.
        #expect(summary.attemptedBatches == 1)
        #expect(summary.succeededEntries == 2)
        #expect(summary.terminalEntries == 0)
        #expect(summary.retryableEntries == 1)
        #expect(summary.acknowledgement == .notAcknowledged)
        // Round 1 + round 2 = 2 `sendBatch` HTTP calls; the
        // active-set shrinks to the single retryable item in
        // round 2.
        #expect(recorder.sentCount == 2)
        // Active-set shrink proof: round 1 dispatched all 3 items
        // in one `_bulk` request, round 2 dispatched only the
        // 1 retryable subset.
        #expect(try Self.bulkRequestItemCounts(recorder.sent) == [3, 1])

        // Follow-up reparses the full retained export artifact; no per-entry
        // cross-flush retry memory.
        let followUp = try await wiring.engine.flush()
        #expect(followUp.succeededEntries == 3)
        #expect(followUp.terminalEntries == 0)
        #expect(followUp.retryableEntries == 0)
        #expect(followUp.acknowledgement == .removedDeliveredBytes)
        #expect(recorder.sentCount == 3)
        // The follow-up dispatched 3 items in one `_bulk` request;
        // the engine reparsed the full export, not just the prior
        // round's retryable subset.
        #expect(try Self.bulkRequestItemCounts(recorder.sent) == [3, 1, 3])
    }

    @Test("empty queue: flush short-circuits with emptyReleased acknowledgement")
    func flushEmptyQueueEmptyReleased() async throws {
        let queueDir = Self.uniqueDirectory()
        let exportDir = Self.uniqueDirectory()
        defer {
            Self.cleanup(queueDir)
            Self.cleanup(exportDir)
        }
        try FileManager.default.createDirectory(
            at: queueDir, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: exportDir, withIntermediateDirectories: true
        )

        let recorder = RecordingTransport()
        let configuration = try Self.makeConfiguration(
            queueDirectory: queueDir, exportDirectory: exportDir
        )
        let wiring = ElasticRemoteEngine.make(configuration, bulkTransport: recorder)

        let summary = try await wiring.engine.flush()
        #expect(summary.attemptedBatches == 0)
        #expect(summary.succeededEntries == 0)
        #expect(summary.terminalEntries == 0)
        #expect(summary.retryableEntries == 0)
        #expect(summary.acknowledgement == .emptyReleased)
        // No queue payload bytes → no transport call.
        #expect(recorder.sentCount == 0)
    }
}
