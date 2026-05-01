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

private func makeIntakeURL() throws -> URL {
    try #require(URL(string: "https://logs.example.com/elastic"))
}

private func makeLogger(
    minimumLevel: ElasticLogger.MinimumLevel = .trace,
    transport: any BulkTransport = RecordingTransport(),
    dateProvider: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 0) }
) throws -> ElasticLogger {
    let url = try makeIntakeURL()
    return ElasticLogger(
        endpoint: .intake(url: url, authorizationHeader: nil),
        serviceName: "test-service",
        minimumLevel: minimumLevel,
        dateProvider: dateProvider,
        transport: transport
    )
}

@Suite("ElasticLogger")
struct ElasticLoggerTests {
    // MARK: Locked surface

    @Test("Initializer stores endpoint, serviceName, and minimumLevel")
    func initializerStoresLockedSurface() throws {
        let url = try makeIntakeURL()
        let logger = ElasticLogger(
            endpoint: .intake(url: url, authorizationHeader: "Bearer xyz"),
            serviceName: "demo-ios",
            minimumLevel: .info
        )

        #expect(logger.serviceName == "demo-ios")
        #expect(logger.minimumLevel == .info)
        guard case let .intake(storedURL, header) = logger.endpoint else {
            Issue.record("expected .intake")
            return
        }
        #expect(storedURL == url)
        #expect(header == "Bearer xyz")
    }

    @Test("MinimumLevel default is .warning")
    func minimumLevelDefaultIsWarning() throws {
        let url = try makeIntakeURL()
        let logger = ElasticLogger(
            endpoint: .intake(url: url, authorizationHeader: nil),
            serviceName: "demo-ios"
        )

        #expect(logger.minimumLevel == .warning)
        #expect(ElasticLogger.MinimumLevel.defaultLevel == .warning)
    }

    @Test("Public initializer without `urlSession` keeps the locked surface")
    func publicInitWithoutURLSessionPreservesLockedSurface() throws {
        let url = try makeIntakeURL()
        let logger = ElasticLogger(
            endpoint: .intake(url: url, authorizationHeader: "Bearer xyz"),
            serviceName: "demo-ios",
            minimumLevel: .info
        )

        #expect(logger.serviceName == "demo-ios")
        #expect(logger.minimumLevel == .info)
        guard case let .intake(storedURL, header) = logger.endpoint else {
            Issue.record("expected .intake")
            return
        }
        #expect(storedURL == url)
        #expect(header == "Bearer xyz")
    }

    @Test("Public initializer accepts an explicit URLSession for enterprise networking")
    func publicInitAcceptsExplicitURLSession() throws {
        let url = try makeIntakeURL()
        // Build a session with a non-default configuration that
        // an enterprise consumer would typically use (custom
        // timeouts, host filter, etc.). We only verify the public
        // surface compiles and that the locked properties read
        // back unchanged; the concrete URLSession is held inside
        // the internal transport and is not part of the public
        // API.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        let logger = ElasticLogger(
            endpoint: .elasticsearch(url: url, apiKey: "abc123"),
            serviceName: "demo-ios",
            minimumLevel: .warning,
            urlSession: session
        )

        #expect(logger.serviceName == "demo-ios")
        #expect(logger.minimumLevel == .warning)
        guard case let .elasticsearch(storedURL, apiKey) = logger.endpoint else {
            Issue.record("expected .elasticsearch")
            return
        }
        #expect(storedURL == url)
        #expect(apiKey == "abc123")
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
        let transport = RecordingTransport()
        let logger = try makeLogger(minimumLevel: .trace, transport: transport)

        logger.log(
            .disabled,
            "Network",
            recordEvaluationAndReturn(messageCounter, LogMessage(stringLiteral: "never evaluated")),
            attributes: recordEvaluationAndReturn(attributesCounter, [LogAttribute]())
        )

        #expect(messageCounter.value == 0)
        #expect(attributesCounter.value == 0)
        #expect(transport.sent.isEmpty)
    }

    @Test("Below-threshold level drops without evaluating message or attributes")
    func belowThresholdIsDroppedWithoutEvaluation() throws {
        let messageCounter = CallCounter()
        let attributesCounter = CallCounter()
        let transport = RecordingTransport()
        let logger = try makeLogger(minimumLevel: .warning, transport: transport)

        logger.log(
            .info,
            "Network",
            recordEvaluationAndReturn(messageCounter, LogMessage(stringLiteral: "never evaluated")),
            attributes: recordEvaluationAndReturn(attributesCounter, [LogAttribute]())
        )

        #expect(messageCounter.value == 0)
        #expect(attributesCounter.value == 0)
        #expect(transport.sent.isEmpty)
    }

    @Test("Dropped entries do not call the transport")
    func droppedEntriesDoNotCallTransport() async throws {
        let url = try makeIntakeURL()
        let transport = RecordingTransport()
        let logger = ElasticLogger(
            endpoint: .intake(url: url, authorizationHeader: nil),
            serviceName: "demo-ios",
            minimumLevel: .warning,
            dateProvider: { Date(timeIntervalSince1970: 0) },
            transport: transport
        )

        logger.log(.info, "Network", "below threshold", attributes: [])
        logger.log(.disabled, "Network", "disabled sentinel", attributes: [])

        // Allow any spurious async dispatch to surface.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(transport.sent.isEmpty)
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

    // MARK: End-to-end delivery path

    @Test("Allowed entry POSTs one ECS-encoded document through the transport")
    func allowedEntryProducesOneTransportCall() async throws {
        let url = try makeIntakeURL()
        let transport = RecordingTransport()
        let fixedDate = Date(timeIntervalSince1970: 1_777_550_400.123)
        let logger = ElasticLogger(
            endpoint: .intake(url: url, authorizationHeader: "Bearer abc"),
            serviceName: "demo-ios",
            minimumLevel: .trace,
            dateProvider: { fixedDate },
            transport: transport
        )

        logger.log(
            .info,
            "Network",
            "User opened screen",
            attributes: [LogAttribute("auth.method", "password")]
        )
        await waitForSendCount(1, on: transport)

        try #require(transport.sent.count == 1)
        let call = transport.sent[0]

        #expect(call.url == url)
        #expect(call.headers["Content-Type"] == "application/x-ndjson")
        #expect(call.headers["Authorization"] == "Bearer abc")

        let document = try ecsDocumentLine(from: call.body)
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: document) as? [String: Any]
        )
        #expect(decoded["@timestamp"] as? String == "2026-04-30T12:00:00.123Z")
        #expect(decoded["log.level"] as? String == "info")
        #expect(decoded["message"] as? String == "User opened screen")
        #expect(decoded["service.name"] as? String == "demo-ios")
        #expect(decoded["event.dataset"] as? String == "swift-loggers")
        #expect(decoded["logger.domain"] as? String == "Network")
        #expect(decoded["auth.method"] as? String == "password")
    }

    @Test("Allowed entry materializes, redacts, encodes, and POSTs after the drop guard")
    func allowedEntryFullPipeline() async throws {
        let url = try makeIntakeURL()
        let transport = RecordingTransport()
        let messageCounter = CallCounter()
        let attributesCounter = CallCounter()
        let logger = ElasticLogger(
            endpoint: .intake(url: url, authorizationHeader: nil),
            serviceName: "demo-ios",
            minimumLevel: .trace,
            dateProvider: { Date(timeIntervalSince1970: 0) },
            transport: transport
        )

        // `.info` at `.trace` threshold passes the drop guard. Mix
        // private and sensitive segments in the message and a
        // private and a sensitive attribute so the redacted shape
        // pins both literals end-to-end.
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
        await waitForSendCount(1, on: transport)

        // Hard-require exactly one transport call before indexing
        // so a zero-call regression fails fast instead of crashing
        // the test process on an out-of-bounds index.
        try #require(transport.sent.count == 1)
        let call = transport.sent[0]

        let document = try ecsDocumentLine(from: call.body)
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: document) as? [String: Any]
        )

        // Redaction ran before the encoder: message segments are
        // collapsed into the redacted text and attribute values are
        // replaced with the redacted literals.
        #expect(decoded["message"] as? String == "User <private> used <redacted>")
        #expect(decoded["auth.username"] as? String == "<private>")
        #expect(decoded["session.token"] as? String == "<redacted>")

        // Raw-JSON view: the original plaintext must not appear
        // anywhere in the encoded body, which pins the
        // redact-before-encode contract end-to-end.
        let raw = try #require(String(data: call.body, encoding: .utf8))
        #expect(!raw.contains("alice"))
        #expect(!raw.contains("secret-token"))
        #expect(raw.contains("<private>"))
        #expect(raw.contains("<redacted>"))

        // Single-evaluation: the autoclosures are evaluated exactly
        // once on the allowed path, even though the value flows
        // through the redactor, the encoder, and the FIFO worker.
        #expect(messageCounter.value == 1)
        #expect(attributesCounter.value == 1)
    }

    // MARK: Direct mode integration

    @Test("Direct endpoint POSTs the encoded payload to <url>/_bulk with ApiKey auth")
    func directEndpointEndToEnd() async throws {
        let cluster = try #require(URL(string: "https://es.example.com"))
        let transport = RecordingTransport()
        let logger = ElasticLogger(
            endpoint: .elasticsearch(url: cluster, apiKey: "abc123"),
            serviceName: "demo-ios",
            minimumLevel: .trace,
            dateProvider: { Date(timeIntervalSince1970: 0) },
            transport: transport
        )

        logger.log(.info, "Network", "hello", attributes: [])
        await waitForSendCount(1, on: transport)

        try #require(transport.sent.count == 1)
        let call = transport.sent[0]

        #expect(call.url.absoluteString == "https://es.example.com/_bulk")
        #expect(call.headers["Authorization"] == "ApiKey abc123")
        #expect(call.headers["Content-Type"] == "application/x-ndjson")

        let raw = try #require(String(data: call.body, encoding: .utf8))
        #expect(raw.hasPrefix(#"{"create":{"_index":"logs-swift-loggers-default"}}"# + "\n"))
        #expect(raw.hasSuffix("\n"))
    }
}
