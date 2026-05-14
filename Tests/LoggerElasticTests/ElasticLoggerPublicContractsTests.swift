import Foundation
import Loggers
import Testing

@testable import LoggerElastic

/// Coverage for the public best-effort customization surface that
/// ``ElasticLogger`` locks in `0.1.0`:
///
/// - ``ElasticDocumentEncoder`` injection (default behaviour
///   parity + custom encoder + encoder-failure diagnostic path).
/// - ``ElasticRecordRedactor`` injection (default fail-closed
///   behaviour preserved + custom redactor path running before
///   encoding).
/// - ``ElasticLoggerDiagnostic`` observable signals (encoder
///   failure, bounded-buffer overflow).
@Suite("ElasticLogger public contracts")
struct ElasticLoggerPublicContractsTests {
    private static func intakeURL() throws -> URL {
        try #require(URL(string: "https://intake.example.test/elastic"))
    }

    private static func makeLogger(
        transport: any BulkTransport,
        encoder: any ElasticDocumentEncoder = DefaultElasticDocumentEncoder(),
        redactor: any ElasticRecordRedactor = DefaultElasticRecordRedactor(),
        onDiagnostic: (@Sendable (ElasticLoggerDiagnostic) -> Void)? = nil,
        queueCapacity: Int = DeliveryWorker.defaultQueueCapacity,
        timestamp: Date = Date(timeIntervalSince1970: 0)
    ) throws -> ElasticLogger {
        try ElasticLogger(
            endpoint: .intake(url: intakeURL(), authorizationHeader: nil),
            serviceName: "contracts-test",
            minimumLevel: .trace,
            dateProvider: { timestamp },
            transport: transport,
            encoder: encoder,
            redactor: redactor,
            onDiagnostic: onDiagnostic,
            queueCapacity: queueCapacity
        )
    }

    // MARK: Default encoder + redactor default behaviour parity

    @Test("Default encoder + redactor still produce ECS JSON without explicit injection")
    func defaultEncoderRedactorParity() async throws {
        let transport = RecordingTransport()
        let logger = try Self.makeLogger(transport: transport)
        logger.log(.info, "Application", "hello", attributes: [])
        await waitForSendCount(1, on: transport)

        let sent = try #require(transport.sent.first)
        let body = sent.body
        let lines = body.split(separator: 0x0A, omittingEmptySubsequences: true)
        try #require(lines.count == 2)
        let document = Data(lines[1])
        let parsed = try JSONSerialization.jsonObject(with: document)
        let object = try #require(parsed as? [String: Any])
        #expect(object["message"] as? String == "hello")
        #expect(object["service.name"] as? String == "contracts-test")
        #expect(object["event.dataset"] as? String == "swift-loggers")
        #expect(object["log.level"] as? String == "info")
    }

    // MARK: Custom encoder

    /// Custom encoder that emits a minimal JSON document
    /// `{"custom":"<message>","sn":"<serviceName>","sensitive":"<value>"}`
    /// so the test can prove the adapter actually went through the
    /// injected encoder (custom keys, not the default ECS field
    /// names), that the `serviceName` argument reached the
    /// encoder, AND that the record reached the encoder already
    /// **redacted** (the encoder reads the sensitive attribute
    /// value verbatim — if it sees the raw plaintext, redaction
    /// did not run before the encoder).
    private struct CustomEncoder: ElasticDocumentEncoder {
        func encode(_ record: LogRecord, serviceName: String) -> Data {
            var sensitive = "<missing>"
            for attribute in record.attributes where attribute.key == "user.token" {
                if case let .string(value) = attribute.value {
                    sensitive = value
                }
            }
            let payload = [
                "custom": record.message.redactedDescription,
                "sn": serviceName,
                "sensitive": sensitive
            ]
            // The test fixture inputs only contain JSON-safe values
            // and the encoder cannot legitimately fail on them, so
            // a fallback empty `Data()` keeps the test infallible
            // without using force-try.
            return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        }
    }

    @Test("Custom encoder receives the redacted record + serviceName context")
    func customEncoderPath() async throws {
        let transport = RecordingTransport()
        let logger = try Self.makeLogger(
            transport: transport,
            encoder: CustomEncoder()
        )
        // Sensitive attribute MUST be replaced with `<redacted>`
        // before the custom encoder sees it. If redaction did not
        // run, the custom encoder would surface the plaintext
        // through the `sensitive` key and the assertion below
        // would fail.
        logger.log(
            .info,
            "Application",
            "custom-doc",
            attributes: [
                LogAttribute(
                    "user.token",
                    .string("plaintext-must-not-leak"),
                    privacy: .sensitive
                )
            ]
        )
        await waitForSendCount(1, on: transport)

        let sent = try #require(transport.sent.first)
        let body = sent.body
        let lines = body.split(separator: 0x0A, omittingEmptySubsequences: true)
        try #require(lines.count == 2)
        let document = Data(lines[1])
        let parsed = try JSONSerialization.jsonObject(with: document)
        let object = try #require(parsed as? [String: Any])
        // Custom encoder emitted its own shape — the default ECS
        // fields are NOT present.
        #expect(object["custom"] as? String == "custom-doc")
        #expect(object["sn"] as? String == "contracts-test")
        #expect(object["message"] == nil)
        #expect(object["service.name"] == nil)
        // Redaction-before-encoding proof: the encoder saw the
        // redacted value, not the original plaintext.
        #expect(object["sensitive"] as? String == "<redacted>")
    }

    // MARK: Encoder failure diagnostic

    private struct EncodingTestError: Error, Sendable, Equatable {
        let identifier: Int
    }

    /// Stateful encoder: the first invocation throws, every later
    /// invocation succeeds with the default ECS shape. Used to
    /// prove a single `ElasticLogger` instance keeps processing
    /// later entries after an encoder failure on an earlier one.
    private final class FailOnceEncoder: ElasticDocumentEncoder, @unchecked Sendable {
        private let lock = NSLock()
        private var threwOnce = false
        let identifier: Int
        let fallback: DefaultElasticDocumentEncoder

        init(identifier: Int) {
            self.identifier = identifier
            fallback = DefaultElasticDocumentEncoder()
        }

        func encode(_ record: LogRecord, serviceName: String) throws -> Data {
            let shouldThrow: Bool = {
                lock.lock()
                defer { lock.unlock() }
                if threwOnce { return false }
                threwOnce = true
                return true
            }()
            if shouldThrow {
                throw EncodingTestError(identifier: identifier)
            }
            return fallback.encode(record, serviceName: serviceName)
        }
    }

    /// Thread-safe collector for `onDiagnostic` callbacks. The
    /// `ElasticLogger` fires the callback synchronously on the
    /// producer thread; tests append into this recorder under a
    /// lock so a concurrent `log` call cannot race with a
    /// snapshot read.
    private final class DiagnosticRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var captured: [ElasticLoggerDiagnostic] = []

        func append(_ diagnostic: ElasticLoggerDiagnostic) {
            lock.lock()
            defer { lock.unlock() }
            captured.append(diagnostic)
        }

        var snapshot: [ElasticLoggerDiagnostic] {
            lock.lock()
            defer { lock.unlock() }
            return captured
        }
    }

    @Test("Encoder failure: entry is dropped, diagnostic fires, later entries keep flowing on the same logger")
    func encoderFailureDiagnostic() async throws {
        let transport = RecordingTransport()
        let recorder = DiagnosticRecorder()
        // Stateful encoder: first call throws, second call
        // succeeds. Both calls hit the same `ElasticLogger`
        // instance, so the test exercises the actual
        // failure-recovery invariant on one logger rather than
        // simulating it across two.
        let logger = try Self.makeLogger(
            transport: transport,
            encoder: FailOnceEncoder(identifier: 0x42),
            onDiagnostic: { recorder.append($0) }
        )

        logger.log(.info, "Application", "will-fail", attributes: [])

        // The failed entry must not reach the transport. Wait a
        // short cooperative tick so a hypothetical mis-routed
        // payload would have time to land at the recorder.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(transport.sentCount == 0)

        // The diagnostic must fire exactly once with the
        // encoder's error.
        var snapshot = recorder.snapshot
        #expect(snapshot.count == 1)
        if case let .encodingFailed(error) = snapshot.first {
            let typed = try #require(error as? EncodingTestError)
            #expect(typed.identifier == 0x42)
        } else {
            Issue.record("expected .encodingFailed diagnostic on first log")
        }

        // Second entry on the SAME logger: the encoder is now
        // past its one-shot throw and emits a normal document.
        logger.log(.info, "Application", "after-recovery", attributes: [])
        await waitForSendCount(1, on: transport)
        #expect(transport.sentCount == 1)

        // The recorder still carries exactly one diagnostic; the
        // second log did not trigger another `.encodingFailed`
        // (or a `.bufferOverflow`).
        snapshot = recorder.snapshot
        #expect(snapshot.count == 1)
    }

    // MARK: Custom redactor

    private struct UppercaseRedactor: ElasticRecordRedactor {
        func redact(_ record: LogRecord) -> LogRecord {
            let upperMessage = LogMessage(segments: [
                LogSegment(
                    record.message.redactedDescription.uppercased(),
                    privacy: .public
                )
            ])
            return LogRecord(
                timestamp: record.timestamp,
                level: record.level,
                domain: record.domain,
                message: upperMessage,
                attributes: record.attributes.map { attribute in
                    LogAttribute(attribute.key, attribute.value, privacy: .public)
                }
            )
        }
    }

    @Test("Custom redactor runs before encoding")
    func customRedactorRunsBeforeEncoder() async throws {
        let transport = RecordingTransport()
        let logger = try Self.makeLogger(
            transport: transport,
            redactor: UppercaseRedactor()
        )
        logger.log(.info, "Application", "shout-me", attributes: [])
        await waitForSendCount(1, on: transport)

        let sent = try #require(transport.sent.first)
        let body = sent.body
        let lines = body.split(separator: 0x0A, omittingEmptySubsequences: true)
        try #require(lines.count == 2)
        let document = Data(lines[1])
        let parsed = try JSONSerialization.jsonObject(with: document)
        let object = try #require(parsed as? [String: Any])
        // The encoder saw the redacted record, so `message` is
        // upper-cased. If the redactor had run AFTER the encoder
        // (or not at all), the message would have stayed
        // lower-case.
        #expect(object["message"] as? String == "SHOUT-ME")
    }

    // MARK: Buffer overflow diagnostic

    @Test("Buffer overflow: drop-newest still applies and `bufferOverflow` diagnostic fires")
    func bufferOverflowDiagnostic() async throws {
        let gate = GatedTransport()
        let recorder = DiagnosticRecorder()
        // Tiny capacity (1) keeps the test fast: the first
        // accepted yield occupies the buffer slot; subsequent
        // yields drop while the gate keeps the consumer stalled.
        let logger = try Self.makeLogger(
            transport: gate,
            onDiagnostic: { recorder.append($0) },
            queueCapacity: 1
        )

        // First yield enters the bounded buffer; gate keeps the
        // consumer task parked so the slot stays occupied.
        logger.log(.info, "Application", "first", attributes: [])
        try await Task.sleep(nanoseconds: 20_000_000)

        // Subsequent yields land on the drop-newest branch. The
        // buffer has one slot; the first stays, the rest drop.
        for index in 0 ..< 5 {
            logger.log(.info, "Application", "overflow-\(index)", attributes: [])
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        let snapshot = recorder.snapshot
        // At least one drop fired the diagnostic. Don't pin the
        // exact count because the consumer task may dequeue the
        // single buffered payload between two producer iterations
        // (gate keeps it parked but the dequeue happens before
        // the `await transport.send`).
        let dropEvents = snapshot.filter {
            if case .bufferOverflow = $0 { return true }
            return false
        }
        #expect(!dropEvents.isEmpty)

        // No encoder failures arrived — the encoder is the
        // default one and all inputs are valid.
        let encoderFailures = snapshot.filter {
            if case .encodingFailed = $0 { return true }
            return false
        }
        #expect(encoderFailures.isEmpty)

        // Open the gate so the worker task can drain and the
        // logger destructor does not stall the suite.
        gate.openGate()
    }

    // MARK: Default redactor default behaviour parity

    @Test("Default redactor replaces private / sensitive attributes before encoding")
    func defaultRedactorParity() async throws {
        let transport = RecordingTransport()
        let logger = try Self.makeLogger(transport: transport)
        logger.log(
            .info,
            "Application",
            "msg",
            attributes: [
                LogAttribute("user.email", .string("nobody@example.test"), privacy: .private),
                LogAttribute("user.token", .string("topsecret"), privacy: .sensitive)
            ]
        )
        await waitForSendCount(1, on: transport)

        let sent = try #require(transport.sent.first)
        let body = sent.body
        let lines = body.split(separator: 0x0A, omittingEmptySubsequences: true)
        try #require(lines.count == 2)
        let document = Data(lines[1])
        let parsed = try JSONSerialization.jsonObject(with: document)
        let object = try #require(parsed as? [String: Any])
        #expect(object["user.email"] as? String == "<private>")
        #expect(object["user.token"] as? String == "<redacted>")
    }

    // MARK: Public initializer forwarding proof

    /// Sentinel error raised by the inspecting encoder used in
    /// ``publicInitializerForwardsCustomSeams``. Carries the
    /// values the encoder observed so the test can assert
    /// forwarding without touching the network.
    private struct ForwardingProofError: Error, Sendable, Equatable {
        let serviceName: String
        let messageText: String
    }

    /// Encoder that throws after capturing the inputs it saw.
    /// Because the encoder always throws, the entry is dropped at
    /// the encode step and the transport is never invoked — the
    /// test does not need a real network or a `BulkTransport`
    /// stub. The `onDiagnostic` callback receives the captured
    /// error and the assertions read its fields.
    private struct InspectingEncoder: ElasticDocumentEncoder {
        func encode(_ record: LogRecord, serviceName: String) throws -> Data {
            throw ForwardingProofError(
                serviceName: serviceName,
                messageText: record.message.redactedDescription
            )
        }
    }

    @Test("Public initializer forwards custom encoder + redactor + onDiagnostic")
    func publicInitializerForwardsCustomSeams() throws {
        // Public init path with the network endpoint set to an
        // intake URL we never reach: the inspecting encoder throws
        // BEFORE the transport is invoked, so the test stays
        // network-free without any internal seam.
        let intakeURL = try Self.intakeURL()
        let recorder = DiagnosticRecorder()
        let logger = ElasticLogger(
            endpoint: .intake(url: intakeURL, authorizationHeader: nil),
            serviceName: "forwarding-test",
            minimumLevel: .trace,
            encoder: InspectingEncoder(),
            redactor: UppercaseRedactor(),
            onDiagnostic: { recorder.append($0) }
        )

        logger.log(
            .info,
            "Forwarding",
            "probe",
            attributes: [
                LogAttribute(
                    "user.token",
                    .string("plaintext-must-not-leak"),
                    privacy: .sensitive
                )
            ]
        )

        // Encoder threw inside `log`; the diagnostic is recorded
        // synchronously on the producer thread, so no wait is
        // needed before reading the recorder.
        let snapshot = recorder.snapshot
        #expect(snapshot.count == 1)
        guard case let .encodingFailed(error) = snapshot.first,
              let proof = error as? ForwardingProofError
        else {
            Issue.record("expected .encodingFailed(ForwardingProofError) from public init path")
            return
        }
        // Three seams the public init forwards:
        // 1. `serviceName` reached the encoder.
        // 2. The custom `redactor` ran before the encoder — the
        //    message text is uppercased by `UppercaseRedactor`
        //    rather than the input `probe`.
        // 3. The custom `onDiagnostic` callback received the
        //    encoder's throw (covered by the `case let
        //    .encodingFailed(error)` match above).
        #expect(proof.serviceName == "forwarding-test")
        #expect(proof.messageText == "PROBE")
    }
}
