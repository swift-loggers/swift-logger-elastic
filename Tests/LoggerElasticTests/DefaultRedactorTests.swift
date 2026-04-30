import Foundation
import Loggers
import Testing

@testable import LoggerElastic

private let fixedTimestamp = Date(timeIntervalSince1970: 0)

private func record(
    message: LogMessage = "x",
    attributes: [LogAttribute] = []
) -> LogRecord {
    LogRecord(
        timestamp: fixedTimestamp,
        level: .info,
        domain: "Network",
        message: message,
        attributes: attributes
    )
}

@Suite("DefaultRedactor")
struct DefaultRedactorTests {
    // MARK: Message redaction

    @Test("Public message segments are kept verbatim")
    func publicMessagePreserved() {
        let redactor = DefaultRedactor()
        let input = record(message: "User opened screen")

        let output = redactor.redact(input)
        let segments = output.message.segments

        #expect(segments.count == 1)
        #expect(segments[0].privacy == .public)
        #expect(segments[0].value == "User opened screen")
    }

    @Test("Private segments are replaced with <private>")
    func privateSegmentsReplaced() {
        let redactor = DefaultRedactor()
        let input = record(message: LogMessage(segments: [
            LogSegment("user="),
            LogSegment("alice", privacy: .private),
            LogSegment(" signed in")
        ]))

        let output = redactor.redact(input)

        #expect(output.message.redactedDescription == "user=<private> signed in")
        #expect(!output.message.redactedDescription.contains("alice"))
    }

    @Test("Sensitive segments are replaced with <redacted>")
    func sensitiveSegmentsReplaced() {
        let redactor = DefaultRedactor()
        let input = record(message: LogMessage(segments: [
            LogSegment("token="),
            LogSegment("api-token-xyz", privacy: .sensitive)
        ]))

        let output = redactor.redact(input)

        #expect(output.message.redactedDescription == "token=<redacted>")
        #expect(!output.message.redactedDescription.contains("api-token-xyz"))
    }

    @Test("Mixed segments collapse into a single .public segment")
    func mixedSegmentsCollapse() {
        let redactor = DefaultRedactor()
        let input = record(message: LogMessage(segments: [
            LogSegment("Hello "),
            LogSegment("alice", privacy: .private),
            LogSegment(" and "),
            LogSegment("bob", privacy: .sensitive)
        ]))

        let output = redactor.redact(input)

        #expect(output.message.segments.count == 1)
        #expect(output.message.segments[0].privacy == .public)
        #expect(output.message.segments[0].value == "Hello <private> and <redacted>")
    }

    // MARK: Attribute redaction

    struct AttributeRedactionCase: Sendable {
        let privacy: LogPrivacy
        let input: LogValue
        let expected: LogValue
    }

    @Test(
        "Attribute redaction by privacy",
        arguments: [
            AttributeRedactionCase(
                privacy: .public,
                input: .string("alice"),
                expected: .string("alice")
            ),
            AttributeRedactionCase(
                privacy: .private,
                input: .string("alice"),
                expected: .string("<private>")
            ),
            AttributeRedactionCase(
                privacy: .sensitive,
                input: .string("alice"),
                expected: .string("<redacted>")
            )
        ]
    )
    func attributeRedaction(testCase: AttributeRedactionCase) {
        let redactor = DefaultRedactor()
        let attribute = LogAttribute("auth.user", testCase.input, privacy: testCase.privacy)
        let inputRecord = record(attributes: [attribute])

        let output = redactor.redact(inputRecord)

        #expect(output.attributes.count == 1)
        #expect(output.attributes[0].key == "auth.user")
        #expect(output.attributes[0].value == testCase.expected)
        // After redaction every attribute is `.public` so the
        // encoder cannot accidentally re-leak based on a stale
        // privacy annotation.
        #expect(output.attributes[0].privacy == .public)
    }

    @Test("Non-string private values are still replaced with <private> string")
    func nonStringPrivateValueReplaced() {
        let redactor = DefaultRedactor()
        let input = record(attributes: [
            LogAttribute("user.id", .integer(42), privacy: .private)
        ])

        let output = redactor.redact(input)

        #expect(output.attributes[0].value == .string("<private>"))
    }

    // MARK: Invariants preserved

    @Test("Timestamp, level, and domain are preserved")
    func recordInvariantsPreserved() {
        let redactor = DefaultRedactor()
        let input = LogRecord(
            timestamp: Date(timeIntervalSince1970: 1000),
            level: .error,
            domain: "Auth",
            message: "boom",
            attributes: []
        )

        let output = redactor.redact(input)

        #expect(output.timestamp == input.timestamp)
        #expect(output.level == input.level)
        #expect(output.domain == input.domain)
    }
}
