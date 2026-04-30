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
}
