import Foundation
import Loggers
import Testing

@testable import LoggerElastic

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func tick() {
        lock.lock()
        defer { lock.unlock() }
        stored += 1
    }
}

private func recordEvaluationAndReturn<T>(
    _ counter: CallCounter,
    _ value: T
) -> T {
    counter.tick()
    return value
}

private func makeLogger(
    minimumLevel: ElasticLogger.MinimumLevel = .trace
) throws -> ElasticLogger {
    let url = try #require(URL(string: "https://logs.example.com/elastic"))
    return ElasticLogger(
        intakeURL: url,
        serviceName: "test-service",
        minimumLevel: minimumLevel
    )
}

@Suite("ElasticLogger")
struct ElasticLoggerTests {
    // MARK: Locked surface

    @Test("Initializer stores intakeURL, serviceName, and minimumLevel")
    func initializerStoresLockedSurface() throws {
        let url = try #require(URL(string: "https://logs.example.com/elastic"))
        let logger = ElasticLogger(
            intakeURL: url,
            serviceName: "demo-ios",
            minimumLevel: .info
        )

        #expect(logger.intakeURL == url)
        #expect(logger.serviceName == "demo-ios")
        #expect(logger.minimumLevel == .info)
    }

    @Test("MinimumLevel default is .warning")
    func minimumLevelDefaultIsWarning() throws {
        let url = try #require(URL(string: "https://logs.example.com/elastic"))
        let logger = ElasticLogger(
            intakeURL: url,
            serviceName: "demo-ios"
        )

        #expect(logger.minimumLevel == .warning)
        #expect(ElasticLogger.MinimumLevel.defaultLevel == .warning)
    }

    @Test("MinimumLevel.allCases is the seven severities in canonical order")
    func minimumLevelAllCasesExactOrder() {
        let cases = ElasticLogger.MinimumLevel.allCases
        let expected: [ElasticLogger.MinimumLevel] = [
            .trace, .debug, .info, .notice, .warning, .error, .critical
        ]

        #expect(cases == expected)
    }

    // MARK: Threshold matrix

    @Test(
        "shouldEmit matrix: every MinimumLevel x every LoggerLevel",
        arguments: [
            (
                ElasticLogger.MinimumLevel.trace,
                [
                    LoggerLevel.trace, .debug, .info, .notice,
                    .warning, .error, .critical
                ]
            ),
            (.debug, [.debug, .info, .notice, .warning, .error, .critical]),
            (.info, [.info, .notice, .warning, .error, .critical]),
            (.notice, [.notice, .warning, .error, .critical]),
            (.warning, [.warning, .error, .critical]),
            (.error, [.error, .critical]),
            (.critical, [.critical])
        ] as [(ElasticLogger.MinimumLevel, [LoggerLevel])]
    )
    func shouldEmitMatrix(
        minimum: ElasticLogger.MinimumLevel,
        expectedPass: [LoggerLevel]
    ) throws {
        let logger = try makeLogger(minimumLevel: minimum)
        let allLevels: [LoggerLevel] = [
            .trace, .debug, .info, .notice, .warning, .error, .critical
        ]

        for level in allLevels {
            let expected = expectedPass.contains(level)
            #expect(
                logger.shouldEmit(level) == expected,
                "minimum=\(minimum) level=\(level) expected=\(expected)"
            )
        }

        // .disabled is a per-message sentinel and must always drop,
        // independent of the configured threshold.
        #expect(
            logger.shouldEmit(.disabled) == false,
            "minimum=\(minimum) disabled must drop"
        )
    }

    // MARK: Drop guard

    @Test("Disabled level drops without evaluating message or attributes")
    func disabledIsDroppedWithoutEvaluation() throws {
        let messageCounter = CallCounter()
        let attributesCounter = CallCounter()
        let logger = try makeLogger(minimumLevel: .trace)

        logger.log(
            .disabled,
            "Network",
            recordEvaluationAndReturn(messageCounter, LogMessage(stringLiteral: "never evaluated")),
            attributes: recordEvaluationAndReturn(attributesCounter, [LogAttribute]())
        )

        #expect(messageCounter.value == 0)
        #expect(attributesCounter.value == 0)
    }

    @Test("Below-threshold level drops without evaluating message or attributes")
    func belowThresholdIsDroppedWithoutEvaluation() throws {
        let messageCounter = CallCounter()
        let attributesCounter = CallCounter()
        let logger = try makeLogger(minimumLevel: .warning)

        logger.log(
            .info,
            "Network",
            recordEvaluationAndReturn(messageCounter, LogMessage(stringLiteral: "never evaluated")),
            attributes: recordEvaluationAndReturn(attributesCounter, [LogAttribute]())
        )

        #expect(messageCounter.value == 0)
        #expect(attributesCounter.value == 0)
    }

    // MARK: Single-evaluation invariant

    @Test("Allowed entry evaluates message and attributes exactly once")
    func allowedEntryEvaluatesEachAutoclosureOnce() throws {
        let messageCounter = CallCounter()
        let attributesCounter = CallCounter()
        let logger = try makeLogger(minimumLevel: .trace)

        logger.log(
            .info,
            "Network",
            recordEvaluationAndReturn(messageCounter, LogMessage(stringLiteral: "evaluated once")),
            attributes: recordEvaluationAndReturn(
                attributesCounter,
                [LogAttribute("auth.method", "password")]
            )
        )

        #expect(messageCounter.value == 1)
        #expect(attributesCounter.value == 1)
    }

    // MARK: End-to-end encode path

    @Test("Allowed entry produces one ECS-encoded payload")
    func allowedEntryProducesOneEncodedPayload() throws {
        let url = try #require(URL(string: "https://logs.example.com/elastic"))
        let recorder = PayloadRecorder()
        let fixedDate = Date(timeIntervalSince1970: 1_777_550_400.123)
        let logger = ElasticLogger(
            intakeURL: url,
            serviceName: "demo-ios",
            minimumLevel: .trace,
            dateProvider: { fixedDate },
            onEncoded: { data in recorder.record(data) }
        )

        logger.log(
            .info,
            "Network",
            "User opened screen",
            attributes: [LogAttribute("auth.method", "password")]
        )

        let payload = try #require(recorder.payloads.first)
        #expect(recorder.payloads.count == 1)

        let decoded = try #require(
            try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )
        #expect(decoded["@timestamp"] as? String == "2026-04-30T12:00:00.123Z")
        #expect(decoded["log.level"] as? String == "info")
        #expect(decoded["message"] as? String == "User opened screen")
        #expect(decoded["service.name"] as? String == "demo-ios")
        #expect(decoded["event.dataset"] as? String == "swift-loggers")
        #expect(decoded["logger.domain"] as? String == "Network")
        #expect(decoded["auth.method"] as? String == "password")
    }

    @Test("Allowed entry redacts private and sensitive content before encoding")
    func allowedEntryRedactsBeforeEncoding() throws {
        let url = try #require(URL(string: "https://logs.example.com/elastic"))
        let recorder = PayloadRecorder()
        let logger = ElasticLogger(
            intakeURL: url,
            serviceName: "demo-ios",
            minimumLevel: .trace,
            dateProvider: { Date(timeIntervalSince1970: 0) },
            onEncoded: { data in recorder.record(data) }
        )

        // Mix all three privacy levels in both message and
        // attributes so a missing redact-before-encode step would
        // surface as plaintext somewhere in the payload.
        logger.log(
            .info,
            "Auth",
            LogMessage(segments: [
                LogSegment("user="),
                LogSegment("alice", privacy: .private),
                LogSegment(" token="),
                LogSegment("api-token-xyz", privacy: .sensitive)
            ]),
            attributes: [
                LogAttribute("auth.method", "password"),
                LogAttribute("auth.username", "alice", privacy: .private),
                LogAttribute("auth.token", "tk-99-secret", privacy: .sensitive)
            ]
        )

        let payload = try #require(recorder.payloads.first)
        #expect(recorder.payloads.count == 1)

        let decoded = try #require(
            try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )

        // Decoded view: message is rendered with the redacted
        // markers, public attribute is preserved verbatim, and
        // private / sensitive attribute values are replaced with
        // their redacted literals before reaching the encoder.
        #expect(decoded["message"] as? String == "user=<private> token=<redacted>")
        #expect(decoded["auth.method"] as? String == "password")
        #expect(decoded["auth.username"] as? String == "<private>")
        #expect(decoded["auth.token"] as? String == "<redacted>")

        // Raw-JSON view: the original plaintext values must not
        // appear anywhere in the encoded `Data`. This pins the
        // invariant that redaction runs before encoding (and
        // therefore before any future enqueue / persistence point
        // that the M3.2 delivery pipeline introduces).
        let raw = try #require(String(data: payload, encoding: .utf8))
        for forbidden in ["alice", "api-token-xyz", "tk-99-secret"] {
            #expect(!raw.contains(forbidden), "leaked: \(forbidden)")
        }
        #expect(raw.contains("<private>"))
        #expect(raw.contains("<redacted>"))
    }

    @Test("Allowed entry materializes, redacts, and encodes payload after the drop guard")
    func allowedEntryFullPipeline() throws {
        let url = try #require(URL(string: "https://logs.example.com/elastic"))
        let recorder = PayloadRecorder()
        let messageCounter = CallCounter()
        let attributesCounter = CallCounter()
        let logger = ElasticLogger(
            intakeURL: url,
            serviceName: "demo-ios",
            minimumLevel: .trace,
            dateProvider: { Date(timeIntervalSince1970: 0) },
            onEncoded: { data in recorder.record(data) }
        )

        // `.info` at `.trace` threshold passes the drop guard.
        // Mix one private and one sensitive segment in the message
        // so the redacted shape pins both literals, and use both a
        // private and a sensitive attribute so the same coverage
        // applies to attribute redaction.
        logger.log(
            .info,
            "Auth",
            recordEvaluationAndReturn(
                messageCounter,
                LogMessage(segments: [
                    LogSegment("User "),
                    LogSegment("alice", privacy: .private),
                    LogSegment(" used "),
                    LogSegment("secret-token", privacy: .sensitive)
                ])
            ),
            attributes: recordEvaluationAndReturn(
                attributesCounter,
                [
                    LogAttribute("auth.username", "alice", privacy: .private),
                    LogAttribute("session.token", "secret-token", privacy: .sensitive)
                ]
            )
        )

        // Hard-require exactly one payload before indexing so a
        // zero- or multi-payload regression fails fast instead of
        // crashing the test process on an out-of-bounds index.
        try #require(recorder.payloads.count == 1)
        let payload = recorder.payloads[0]

        let decoded = try #require(
            try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )

        // Redaction ran before the encoder: message segments are
        // collapsed into the redacted text and attribute values are
        // replaced with the redacted literals.
        #expect(decoded["message"] as? String == "User <private> used <redacted>")
        #expect(decoded["auth.username"] as? String == "<private>")
        #expect(decoded["session.token"] as? String == "<redacted>")

        // Raw-JSON view: the original plaintext must not appear
        // anywhere in the encoded `Data`, which pins the
        // redact-before-encode contract end-to-end.
        let raw = try #require(String(data: payload, encoding: .utf8))
        #expect(!raw.contains("alice"))
        #expect(!raw.contains("secret-token"))
        #expect(raw.contains("<private>"))
        #expect(raw.contains("<redacted>"))

        // Single-evaluation: the autoclosures are evaluated exactly
        // once on the allowed path, even though the value flows
        // through the redactor and the encoder.
        #expect(messageCounter.value == 1)
        #expect(attributesCounter.value == 1)
    }

    @Test("Below-threshold and disabled entries do not reach the encoded sink")
    func droppedEntriesDoNotReachSink() throws {
        let url = try #require(URL(string: "https://logs.example.com/elastic"))
        let recorder = PayloadRecorder()
        let logger = ElasticLogger(
            intakeURL: url,
            serviceName: "demo-ios",
            minimumLevel: .warning,
            dateProvider: { Date(timeIntervalSince1970: 0) },
            onEncoded: { data in recorder.record(data) }
        )

        logger.log(.info, "Network", "below threshold", attributes: [])
        logger.log(.disabled, "Network", "disabled sentinel", attributes: [])

        #expect(recorder.payloads.isEmpty)
    }
}

private final class PayloadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Data] = []

    var payloads: [Data] {
        lock.lock()
        defer { lock.unlock() }
        // Return a defensive snapshot so the caller owns its own
        // array buffer after the lock is released. Plain `return
        // stored` would share buffer storage with the recorder via
        // copy-on-write, which is fine for sequential reads but
        // brittle to reason about under concurrent recording.
        return stored.map { $0 }
    }

    func record(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(data)
    }
}
