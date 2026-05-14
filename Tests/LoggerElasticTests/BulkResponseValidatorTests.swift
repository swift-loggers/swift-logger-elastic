import Foundation
import Testing

@testable import LoggerElastic

@Suite("validateElasticBulkResponse")
struct BulkResponseValidatorTests {
    // MARK: Accepted shapes

    @Test("`errors: false` with a single item validates as success")
    func errorsFalseSingleItemAccepted() throws {
        let body = Data(
            #"{"took":3,"errors":false,"items":[{"create":{"status":201}}]}"#
                .utf8
        )
        try validateElasticBulkResponse(body)
    }

    // MARK: Item-level failures

    @Test("`errors: true` with a single item throws bulkItemFailures (exact case)")
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

    @Test("`items` array of length zero throws malformedBulkResponse")
    func zeroItemsThrows() {
        // Best-effort direct path always POSTs exactly one
        // document, so a zero-item response does not correlate
        // with the request the worker sent.
        let body = Data(#"{"took":3,"errors":false,"items":[]}"#.utf8)
        #expect(throws: BulkTransportError.malformedBulkResponse) {
            try validateElasticBulkResponse(body)
        }
    }

    @Test("`items` array of length greater than one throws malformedBulkResponse")
    func multipleItemsThrows() {
        // Same invariant as the zero-item case: a multi-item
        // response does not correlate with the worker's
        // single-document `_bulk` request.
        let body = Data(
            #"{"took":3,"errors":false,"items":[{"create":{"status":201}},{"create":{"status":201}}]}"#
                .utf8
        )
        #expect(throws: BulkTransportError.malformedBulkResponse) {
            try validateElasticBulkResponse(body)
        }
    }

    @Test("`errors: true` with a wrong item count throws malformedBulkResponse (count check runs before errors check)")
    func errorsTrueWithCountMismatchPrefersMalformed() {
        // Pins the validation order: count mismatch fails closed
        // as `malformedBulkResponse` regardless of the top-level
        // `errors` flag, so a multi-item response (which the
        // best-effort worker never requests) cannot squeak through
        // as `bulkItemFailures` and let the caller assume the
        // shape matched.
        let body = Data(
            #"{"took":3,"errors":true,"items":[{"create":{"status":400}},{"create":{"status":400}}]}"#
                .utf8
        )
        #expect(throws: BulkTransportError.malformedBulkResponse) {
            try validateElasticBulkResponse(body)
        }
    }
}
