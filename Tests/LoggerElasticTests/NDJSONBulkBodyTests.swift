import Foundation
import Testing

@testable import LoggerElastic

@Suite("NDJSONBulkBody")
struct NDJSONBulkBodyTests {
    @Test("Action line targets the swift-loggers ECS data stream via `create`")
    func actionLineShape() {
        #expect(
            NDJSONBulkBody.actionLine
                == #"{"create":{"_index":"logs-swift-loggers-default"}}"#
        )
    }

    @Test("make(document:) emits action line, newline, document, newline")
    func bulkBodyLayout() throws {
        let document = Data(#"{"@timestamp":"2026-04-30T12:00:00.000Z"}"#.utf8)
        let body = NDJSONBulkBody.make(document: document)

        let raw = try #require(String(data: body, encoding: .utf8))
        let expected = """
        {"create":{"_index":"logs-swift-loggers-default"}}
        {"@timestamp":"2026-04-30T12:00:00.000Z"}

        """
        #expect(raw == expected)
    }

    @Test("Body has exactly two newlines (one after the action line, one after the document)")
    func newlineCount() {
        let body = NDJSONBulkBody.make(document: Data("{}".utf8))
        let newlines = body.filter { $0 == 0x0A }.count

        #expect(newlines == 2)
    }

    @Test("Document ending with newline does not produce a double-newline body")
    func documentWithTrailingNewline() throws {
        // Caller passes a document that already ends with `\n`. The
        // framing contract is "body ends with exactly one newline",
        // so the helper must reuse the document's own trailing
        // newline as the framing newline rather than appending a
        // second one. A double `\n` at the end would split the
        // payload into two NDJSON records on the wire.
        let document = Data(#"{"k":1}"#.utf8 + [0x0A])
        let body = NDJSONBulkBody.make(document: document)

        let raw = try #require(String(data: body, encoding: .utf8))
        let expected = """
        {"create":{"_index":"logs-swift-loggers-default"}}
        {"k":1}

        """
        #expect(raw == expected)

        // Total newlines stays at 2 (one between action and doc,
        // one trailing) regardless of whether the document brought
        // its own newline.
        let newlines = body.filter { $0 == 0x0A }.count
        #expect(newlines == 2)
    }
}
