import Foundation
import Testing

@testable import LoggerElastic

/// Parser-level coverage for ``ElasticBulkResponseParser`` that
/// pins each ``ElasticBulkError`` case to a concrete malformed
/// shape. ``ElasticRemoteTransportTests`` drives the parser through
/// scripted HTTP responses; this suite asserts the error taxonomy
/// directly so the diagnostic surface stays narrow.
@Suite("ElasticBulkResponseParser error taxonomy")
struct ElasticBulkResponseParserTests {
    @Test("empty body surfaces .emptyBulkResponse")
    func emptyBodyMapsToEmptyError() throws {
        do {
            _ = try ElasticBulkResponseParser.parse(Data())
            Issue.record("expected throw for empty body")
        } catch let bulkError as ElasticBulkError {
            #expect(bulkError == .emptyBulkResponse)
        }
    }

    @Test("non-JSON body surfaces .invalidBulkResponseJSON")
    func nonJSONMapsToInvalidJSONError() throws {
        do {
            _ = try ElasticBulkResponseParser.parse(Data("{not json".utf8))
            Issue.record("expected throw for invalid JSON")
        } catch let bulkError as ElasticBulkError {
            #expect(bulkError == .invalidBulkResponseJSON)
        }
    }

    @Test("valid JSON with wrong top-level shape surfaces .malformedBulkResponse")
    func wrongTopLevelMapsToMalformed() throws {
        // Valid JSON, but a top-level array — not the documented
        // object envelope.
        let arrayBody = try JSONSerialization.data(withJSONObject: [Int]())
        do {
            _ = try ElasticBulkResponseParser.parse(arrayBody)
            Issue.record("expected throw for top-level array")
        } catch let bulkError as ElasticBulkError {
            #expect(bulkError == .malformedBulkResponse)
        }
    }

    @Test("envelope missing items array surfaces .malformedBulkResponse")
    func missingItemsMapsToMalformed() throws {
        let envelope: [String: Any] = ["errors": false]
        let body = try JSONSerialization.data(withJSONObject: envelope)
        do {
            _ = try ElasticBulkResponseParser.parse(body)
            Issue.record("expected throw for missing items array")
        } catch let bulkError as ElasticBulkError {
            #expect(bulkError == .malformedBulkResponse)
        }
    }

    @Test("multi-key item action object surfaces .malformedBulkResponse")
    func multiKeyItemMapsToMalformed() throws {
        let envelope: [String: Any] = [
            "errors": false,
            "items": [
                [
                    "create": ["status": 201],
                    "index": ["status": 201]
                ]
            ]
        ]
        let body = try JSONSerialization.data(withJSONObject: envelope)
        do {
            _ = try ElasticBulkResponseParser.parse(body)
            Issue.record("expected throw for multi-key item action object")
        } catch let bulkError as ElasticBulkError {
            #expect(bulkError == .malformedBulkResponse)
        }
    }

    @Test("unknown action key surfaces .malformedBulkResponse")
    func unknownActionKeyMapsToMalformed() throws {
        let envelope: [String: Any] = [
            "errors": false,
            "items": [
                ["nonsense_action": ["status": 201]]
            ]
        ]
        let body = try JSONSerialization.data(withJSONObject: envelope)
        do {
            _ = try ElasticBulkResponseParser.parse(body)
            Issue.record("expected throw for unknown action key")
        } catch let bulkError as ElasticBulkError {
            #expect(bulkError == .malformedBulkResponse)
        }
    }

    @Test("item without integer status surfaces .responseItemMissingStatus")
    func missingStatusMapsToMissingStatus() throws {
        let envelope: [String: Any] = [
            "errors": false,
            "items": [
                ["create": ["_index": "logs"]]
            ]
        ]
        let body = try JSONSerialization.data(withJSONObject: envelope)
        do {
            _ = try ElasticBulkResponseParser.parse(body)
            Issue.record("expected throw for missing status")
        } catch let bulkError as ElasticBulkError {
            #expect(bulkError == .responseItemMissingStatus)
        }
    }

    @Test("well-formed mixed response carries action + status + errorType per item in order")
    func wellFormedResponseCarriesActionAndStatus() throws {
        let envelope: [String: Any] = [
            "errors": true,
            "items": [
                ["create": ["status": 201]],
                ["index": [
                    "status": 400,
                    "error": ["type": "mapper_parsing_exception"]
                ]],
                ["create": ["status": 429]]
            ]
        ]
        let body = try JSONSerialization.data(withJSONObject: envelope)
        let parsed = try ElasticBulkResponseParser.parse(body)
        try #require(parsed.count == 3)
        #expect(parsed[0] == ElasticBulkResponseItem(
            action: .create, status: 201, errorType: nil
        ))
        #expect(parsed[1] == ElasticBulkResponseItem(
            action: .index, status: 400, errorType: "mapper_parsing_exception"
        ))
        #expect(parsed[2] == ElasticBulkResponseItem(
            action: .create, status: 429, errorType: nil
        ))
    }
}

/// Direct coverage for ``ElasticBulkItemClassification.classify(status:)``
/// so the per-item status mapping table stays pinned independently
/// of the parser and the transport tests.
@Suite("ElasticBulkItemClassification status mapping")
struct ElasticBulkItemClassificationTests {
    @Test("status 200 and 201 are .success; no other 2xx counts as success")
    func successWindowIsExactly200And201() {
        #expect(ElasticBulkItemClassification.classify(status: 200) == .success)
        #expect(ElasticBulkItemClassification.classify(status: 201) == .success)
        // Unrecognized 2xx codes do not signal a per-item write
        // acceptance the adapter can interpret; they must fall
        // through to terminal rather than be silently treated as
        // success.
        #expect(ElasticBulkItemClassification.classify(status: 202) == .terminal)
        #expect(ElasticBulkItemClassification.classify(status: 204) == .terminal)
        #expect(ElasticBulkItemClassification.classify(status: 299) == .terminal)
    }

    @Test("429 and 5xx are .retryable")
    func retryableWindow() {
        #expect(ElasticBulkItemClassification.classify(status: 429) == .retryable)
        #expect(ElasticBulkItemClassification.classify(status: 500) == .retryable)
        #expect(ElasticBulkItemClassification.classify(status: 503) == .retryable)
        #expect(ElasticBulkItemClassification.classify(status: 599) == .retryable)
    }

    @Test("409 is locked to .terminal as a product decision")
    func conflict409IsTerminal() {
        #expect(ElasticBulkItemClassification.classify(status: 409) == .terminal)
    }

    @Test("non-special 4xx falls through to .terminal")
    func other4xxTerminal() {
        #expect(ElasticBulkItemClassification.classify(status: 400) == .terminal)
        #expect(ElasticBulkItemClassification.classify(status: 401) == .terminal)
        #expect(ElasticBulkItemClassification.classify(status: 404) == .terminal)
    }
}
