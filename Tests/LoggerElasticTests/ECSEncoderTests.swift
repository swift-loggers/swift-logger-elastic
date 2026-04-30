import Foundation
import Loggers
import Testing

@testable import LoggerElastic

// 1_777_550_400 seconds since the Unix epoch is 2026-04-30 12:00:00 UTC;
// the .123 tail exercises the millisecond field of the encoder's
// timestamp formatter.
private let fixedTimestamp = Date(timeIntervalSince1970: 1_777_550_400.123)
private let fixedTimestampString = "2026-04-30T12:00:00.123Z"

private func makeRecord(
    level: LoggerLevel = .info,
    domain: LoggerDomain = "Network",
    message: LogMessage = "User opened screen",
    attributes: [LogAttribute] = []
) -> LogRecord {
    LogRecord(
        timestamp: fixedTimestamp,
        level: level,
        domain: domain,
        message: message,
        attributes: attributes
    )
}

private func decodeJSONObject(_ data: Data) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: data, options: [])
    return try #require(object as? [String: Any])
}

@Suite("ECSEncoder")
struct ECSEncoderTests {
    // MARK: Golden shape

    @Test("Encodes the canonical ECS shape with the six reserved fields")
    func encodesCanonicalReservedFields() throws {
        let encoder = ECSEncoder()
        let record = makeRecord()

        let data = encoder.encode(record, serviceName: "demo-ios")
        let decoded = try decodeJSONObject(data)

        #expect(decoded["@timestamp"] as? String == fixedTimestampString)
        #expect(decoded["log.level"] as? String == "info")
        #expect(decoded["message"] as? String == "User opened screen")
        #expect(decoded["service.name"] as? String == "demo-ios")
        #expect(decoded["event.dataset"] as? String == "swift-loggers")
        #expect(decoded["logger.domain"] as? String == "Network")
        #expect(decoded["labels"] == nil)
    }

    @Test("event.dataset is the literal `swift-loggers`")
    func eventDatasetIsSwiftLoggers() {
        #expect(ECSEncoder.dataset == "swift-loggers")
    }

    @Test("Top-level JSON keys are emitted in sorted order")
    func topLevelKeysAreSorted() throws {
        let encoder = ECSEncoder()
        let record = makeRecord(attributes: [
            LogAttribute("zeta.last", "z"),
            LogAttribute("alpha.first", "a")
        ])

        let data = encoder.encode(record, serviceName: "demo-ios")
        let json = try #require(String(data: data, encoding: .utf8))

        // JSONSerialization.sortedKeys produces lexicographically
        // sorted top-level keys; pin a few neighbours so a future
        // change to an unsorted writer fails this test.
        let timestampIdx = try #require(json.range(of: "\"@timestamp\""))
        let alphaIdx = try #require(json.range(of: "\"alpha.first\""))
        let logLevelIdx = try #require(json.range(of: "\"log.level\""))
        let zetaIdx = try #require(json.range(of: "\"zeta.last\""))

        #expect(timestampIdx.lowerBound < alphaIdx.lowerBound)
        #expect(alphaIdx.lowerBound < logLevelIdx.lowerBound)
        #expect(logLevelIdx.lowerBound < zetaIdx.lowerBound)
    }

    // MARK: Severity matrix

    @Test(
        "log.level uses canonical lowercase severity strings",
        arguments: [
            (LoggerLevel.trace, "trace"),
            (.debug, "debug"),
            (.info, "info"),
            (.notice, "notice"),
            (.warning, "warning"),
            (.error, "error"),
            (.critical, "critical")
        ] as [(LoggerLevel, String)]
    )
    func logLevelMatrix(level: LoggerLevel, expected: String) throws {
        let encoder = ECSEncoder()
        let record = makeRecord(level: level)

        let data = encoder.encode(record, serviceName: "demo-ios")
        let decoded = try decodeJSONObject(data)

        #expect(decoded["log.level"] as? String == expected)
    }

    // MARK: Timestamp format

    @Test("@timestamp is ISO 8601 UTC with millisecond precision")
    func timestampFormatIsIsoMillisUTC() throws {
        let encoder = ECSEncoder()
        let epoch = Date(timeIntervalSince1970: 0)
        let record = LogRecord(
            timestamp: epoch,
            level: .info,
            domain: "Network",
            message: "x",
            attributes: []
        )

        let data = encoder.encode(record, serviceName: "demo-ios")
        let decoded = try decodeJSONObject(data)

        #expect(decoded["@timestamp"] as? String == "1970-01-01T00:00:00.000Z")
    }

    // MARK: Attribute value types

    @Test("LogValue cases round-trip into JSON-native types")
    func attributeValueTypesRoundTrip() throws {
        let encoder = ECSEncoder()
        let nestedDate = Date(timeIntervalSince1970: 0)
        let record = makeRecord(attributes: [
            LogAttribute("a.string", .string("hello")),
            LogAttribute("a.int", .integer(42)),
            LogAttribute("a.double", .double(3.5)),
            LogAttribute("a.bool", .bool(true)),
            LogAttribute("a.date", .date(nestedDate)),
            LogAttribute("a.array", .array([.integer(1), .string("two")])),
            LogAttribute("a.object", .object(["k": .integer(7)])),
            LogAttribute("a.null", .null)
        ])

        let data = encoder.encode(record, serviceName: "demo-ios")
        let decoded = try decodeJSONObject(data)

        #expect(decoded["a.string"] as? String == "hello")
        #expect(decoded["a.int"] as? Int64 == 42)
        #expect(decoded["a.double"] as? Double == 3.5)
        #expect(decoded["a.bool"] as? Bool == true)
        #expect(decoded["a.date"] as? String == "1970-01-01T00:00:00.000Z")

        let array = try #require(decoded["a.array"] as? [Any])
        #expect(array.count == 2)
        #expect(array[0] as? Int64 == 1)
        #expect(array[1] as? String == "two")

        let nested = try #require(decoded["a.object"] as? [String: Any])
        #expect(nested["k"] as? Int64 == 7)

        #expect(decoded["a.null"] is NSNull)
    }

    // MARK: Reserved-key collisions

    @Test("User attributes that collide with reserved keys move to labels")
    func collidingAttributesGoToLabelsNamespace() throws {
        let encoder = ECSEncoder()
        let record = makeRecord(attributes: [
            LogAttribute("@timestamp", "1970-01-01T00:00:00.000Z"),
            LogAttribute("log.level", "evil"),
            LogAttribute("message", "evil"),
            LogAttribute("service.name", "evil"),
            LogAttribute("event.dataset", "evil"),
            LogAttribute("logger.domain", "evil"),
            LogAttribute("safe.key", "kept")
        ])

        let data = encoder.encode(record, serviceName: "demo-ios")
        let decoded = try decodeJSONObject(data)

        // Reserved fields keep their canonical record-derived values.
        #expect(decoded["@timestamp"] as? String == fixedTimestampString)
        #expect(decoded["log.level"] as? String == "info")
        #expect(decoded["message"] as? String == "User opened screen")
        #expect(decoded["service.name"] as? String == "demo-ios")
        #expect(decoded["event.dataset"] as? String == "swift-loggers")
        #expect(decoded["logger.domain"] as? String == "Network")

        // Non-colliding attribute stays at top level.
        #expect(decoded["safe.key"] as? String == "kept")

        // Colliding attributes are preserved under `labels`.
        let labels = try #require(decoded["labels"] as? [String: Any])
        #expect(labels.count == 6)
        #expect(labels["@timestamp"] as? String == "1970-01-01T00:00:00.000Z")
        #expect(labels["log.level"] as? String == "evil")
        #expect(labels["message"] as? String == "evil")
        #expect(labels["service.name"] as? String == "evil")
        #expect(labels["event.dataset"] as? String == "evil")
        #expect(labels["logger.domain"] as? String == "evil")
    }

    @Test("`labels` is itself reserved so a colliding attribute cannot evict the user's labels")
    func labelsKeyIsReserved() throws {
        let encoder = ECSEncoder()
        let record = makeRecord(attributes: [
            // User attribute named `labels`. Without `labels` being
            // reserved, the colliding-collision pass below would
            // overwrite this value with the inner labels object.
            LogAttribute("labels", "kept-by-user"),
            LogAttribute("@timestamp", "1970-01-01T00:00:00.000Z")
        ])

        let data = encoder.encode(record, serviceName: "demo-ios")
        let decoded = try decodeJSONObject(data)

        // The reserved `@timestamp` keeps the canonical value.
        #expect(decoded["@timestamp"] as? String == fixedTimestampString)

        // Both colliding attributes are preserved under the `labels`
        // namespace so neither user attribute is silently dropped.
        let labels = try #require(decoded["labels"] as? [String: Any])
        #expect(labels.count == 2)
        #expect(labels["labels"] as? String == "kept-by-user")
        #expect(labels["@timestamp"] as? String == "1970-01-01T00:00:00.000Z")
    }

    // MARK: Concurrency

    @Test("Concurrent encodes produce identical output and do not race")
    func concurrentEncodesAreSafe() async {
        let encoder = ECSEncoder()
        let record = makeRecord(attributes: [
            LogAttribute("auth.method", "password"),
            LogAttribute("auth.success", true)
        ])

        let outputs = await withTaskGroup(of: Data.self) { group in
            for _ in 0 ..< 200 {
                group.addTask {
                    encoder.encode(record, serviceName: "demo-ios")
                }
            }
            var collected: [Data] = []
            for await data in group {
                collected.append(data)
            }
            return collected
        }

        #expect(outputs.count == 200)
        // Identical inputs must produce identical bytes; a torn read
        // of the shared `DateFormatter` would surface either as a
        // crash, a corrupted timestamp, or a divergent payload.
        let first = outputs[0]
        for data in outputs {
            #expect(data == first)
        }
    }

    // MARK: Non-finite doubles

    @Test("Non-finite double values encode as JSON null instead of throwing")
    func nonFiniteDoublesEncodeAsNull() throws {
        let encoder = ECSEncoder()
        let record = makeRecord(attributes: [
            LogAttribute("metric.nan", .double(.nan)),
            LogAttribute("metric.inf", .double(.infinity)),
            LogAttribute("metric.neg_inf", .double(-.infinity))
        ])

        let data = encoder.encode(record, serviceName: "demo-ios")
        let decoded = try decodeJSONObject(data)

        #expect(decoded["metric.nan"] is NSNull)
        #expect(decoded["metric.inf"] is NSNull)
        #expect(decoded["metric.neg_inf"] is NSNull)
    }

    // MARK: Plaintext leak guard

    @Test("Encoder output does not contain redacted plaintext")
    func encoderDoesNotLeakRedactedPlaintext() throws {
        // The encoder is the last step in the pipeline; the redactor
        // is responsible for producing safe text. Simulate the
        // contract by passing a record whose private and sensitive
        // segments and attribute values have already been replaced
        // with the redacted literals, and verify the original
        // plaintext does not appear in the encoded `Data`.
        let encoder = ECSEncoder()
        let redactor = DefaultRedactor()
        let original = makeRecord(
            message: LogMessage(segments: [
                LogSegment("Hello "),
                LogSegment("super-secret-password", privacy: .private),
                LogSegment(" and "),
                LogSegment("api-token-xyz", privacy: .sensitive)
            ]),
            attributes: [
                LogAttribute("auth.username", "alice", privacy: .private),
                LogAttribute("auth.token", "tk-99-secret", privacy: .sensitive),
                LogAttribute("auth.method", "password")
            ]
        )

        let redacted = redactor.redact(original)
        let data = encoder.encode(redacted, serviceName: "demo-ios")
        let json = try #require(String(data: data, encoding: .utf8))

        for forbidden in [
            "super-secret-password",
            "api-token-xyz",
            "alice",
            "tk-99-secret"
        ] {
            #expect(!json.contains(forbidden), "leaked: \(forbidden)")
        }

        // Public content is preserved.
        #expect(json.contains("Hello "))
        #expect(json.contains("password"))
        // Redacted markers are present.
        #expect(json.contains("<private>"))
        #expect(json.contains("<redacted>"))
    }

    // MARK: Defensive fallback

    @Test("Minimal reserved fallback contains all six reserved fields in sorted order")
    func minimalReservedFallbackShape() throws {
        let data = ECSEncoder.minimalReservedFallback(
            timestamp: "2026-04-30T12:00:00.123Z",
            level: "info",
            message: "User opened screen",
            serviceName: "demo-ios",
            domain: "Network"
        )

        let json = try #require(String(data: data, encoding: .utf8))
        let expected = """
        {\
        "@timestamp":"2026-04-30T12:00:00.123Z",\
        "event.dataset":"swift-loggers",\
        "log.level":"info",\
        "logger.domain":"Network",\
        "message":"User opened screen",\
        "service.name":"demo-ios"\
        }
        """
        #expect(json == expected)

        // The hand-built fallback must still parse as valid JSON
        // with the six canonical keys.
        let decoded = try decodeJSONObject(data)
        #expect(decoded["@timestamp"] as? String == "2026-04-30T12:00:00.123Z")
        #expect(decoded["log.level"] as? String == "info")
        #expect(decoded["message"] as? String == "User opened screen")
        #expect(decoded["service.name"] as? String == "demo-ios")
        #expect(decoded["event.dataset"] as? String == "swift-loggers")
        #expect(decoded["logger.domain"] as? String == "Network")
    }

    @Test("Minimal reserved fallback escapes JSON metacharacters")
    func minimalReservedFallbackEscapesStrings() throws {
        let data = ECSEncoder.minimalReservedFallback(
            timestamp: "2026-04-30T12:00:00.000Z",
            level: "info",
            // Embed a quote, a backslash, a newline, a tab, and a
            // C0 control character to exercise every branch of the
            // local jsonEscape helper.
            message: "line1\"\\\n\tend\u{01}",
            serviceName: "demo-ios",
            domain: "Network"
        )

        // The fallback output must round-trip through JSONSerialization
        // (the parser, not the writer) to count as well-formed JSON.
        let decoded = try decodeJSONObject(data)
        #expect(decoded["message"] as? String == "line1\"\\\n\tend\u{01}")
    }
}
