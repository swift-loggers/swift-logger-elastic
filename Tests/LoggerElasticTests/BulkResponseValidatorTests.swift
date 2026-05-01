import Foundation
import Testing

@testable import LoggerElastic

@Suite("validateElasticBulkResponse")
struct BulkResponseValidatorTests {
    // MARK: Accepted shapes

    @Test("`errors: false` validates as success")
    func errorsFalseAccepted() throws {
        let body = Data(#"{"took":3,"errors":false,"items":[]}"#.utf8)
        try validateElasticBulkResponse(body)
    }

    // MARK: Item-level failures

    @Test("`errors: true` throws bulkItemFailures (exact case)")
    func errorsTrueThrowsBulkItemFailures() {
        let body = Data(
            #"{"took":3,"errors":true,"items":[{"create":{"status":400}}]}"#
                .utf8
        )
        #expect(throws: BulkTransportError.bulkItemFailures) {
            try validateElasticBulkResponse(body)
        }
    }

    // MARK: Malformed shapes

    // Direct path is strict. Each test pins the *exact*
    // `BulkTransportError.malformedBulkResponse` case so a
    // regression that mixes up `bulkItemFailures` and
    // `malformedBulkResponse` cannot pass.

    @Test("Empty body throws malformedBulkResponse")
    func emptyBodyThrows() {
        #expect(throws: BulkTransportError.malformedBulkResponse) {
            try validateElasticBulkResponse(Data())
        }
    }

    @Test("Non-JSON body throws malformedBulkResponse")
    func nonJSONBodyThrows() {
        #expect(throws: BulkTransportError.malformedBulkResponse) {
            try validateElasticBulkResponse(Data("OK".utf8))
        }
        #expect(throws: BulkTransportError.malformedBulkResponse) {
            try validateElasticBulkResponse(Data("<html>thanks</html>".utf8))
        }
    }

    @Test("Top-level JSON array throws malformedBulkResponse")
    func topLevelArrayThrows() {
        #expect(throws: BulkTransportError.malformedBulkResponse) {
            try validateElasticBulkResponse(Data("[]".utf8))
        }
        #expect(throws: BulkTransportError.malformedBulkResponse) {
            try validateElasticBulkResponse(Data(#"[{"errors":false,"items":[]}]"#.utf8))
        }
    }

    @Test("JSON without an `errors` field throws malformedBulkResponse")
    func missingErrorsFieldThrows() {
        let body = Data(#"{"took":3,"items":[]}"#.utf8)
        #expect(throws: BulkTransportError.malformedBulkResponse) {
            try validateElasticBulkResponse(body)
        }
    }

    @Test("Non-boolean `errors` value throws malformedBulkResponse")
    func nonBooleanErrorsFieldThrows() {
        let body = Data(#"{"took":3,"errors":"oops","items":[]}"#.utf8)
        #expect(throws: BulkTransportError.malformedBulkResponse) {
            try validateElasticBulkResponse(body)
        }
    }

    @Test("`errors:false` without `items` throws malformedBulkResponse")
    func missingItemsFieldThrows() {
        let body = Data(#"{"took":3,"errors":false}"#.utf8)
        #expect(throws: BulkTransportError.malformedBulkResponse) {
            try validateElasticBulkResponse(body)
        }
    }

    @Test("Non-array `items` value throws malformedBulkResponse")
    func nonArrayItemsFieldThrows() {
        let body = Data(#"{"took":3,"errors":false,"items":"oops"}"#.utf8)
        #expect(throws: BulkTransportError.malformedBulkResponse) {
            try validateElasticBulkResponse(body)
        }
    }
}
