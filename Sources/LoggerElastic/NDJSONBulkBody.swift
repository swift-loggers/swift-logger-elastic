import Foundation

/// Internal helper that wraps an encoded document in the two-line
/// NDJSON shape the Elasticsearch `_bulk` endpoint expects: an
/// action line followed by the document, each terminated by a
/// newline (`0x0A`). The helper does no document encoding itself;
/// it only frames bytes the configured encoder produced.
///
/// The built-in direct-path action line targets the ECS
/// data-streams convention for general-purpose log indices:
/// `logs-<dataset>-default` resolves to
/// `logs-swift-loggers-default`, matching the `event.dataset`
/// field ``DefaultElasticDocumentEncoder`` stamps on every
/// document. Custom ``ElasticDocumentEncoder`` implementations
/// reuse this built-in direct index without contributing an
/// `event.dataset` field of their own; hosts that need a
/// different index target route through an intake endpoint or
/// the durable ``ElasticRemoteEngine`` configuration instead.
enum NDJSONBulkBody {
    /// The fixed action line emitted before every document. Uses
    /// `create` (not `index`) so the request also works against an
    /// Elasticsearch data stream where `index` is rejected. The
    /// `String` form is kept for tests and human-readable usage;
    /// the hot path appends ``actionLineData`` instead so each
    /// `make(document:)` call avoids the per-call UTF-8 conversion.
    static let actionLine = #"{"create":{"_index":"logs-swift-loggers-default"}}"#

    /// UTF-8-encoded form of ``actionLine``, cached so
    /// ``make(document:)`` can reach for a `Data` value directly
    /// instead of re-encoding the string on every call.
    static let actionLineData = Data(actionLine.utf8)

    /// Builds the NDJSON body for a single encoded document.
    /// Layout: `<action line>\n<document>\n`.
    ///
    /// The body always ends with exactly one trailing newline. If
    /// `document` already ends with `0x0A` (for example, because a
    /// caller built the document with its own trailing newline),
    /// the helper does not add a second one, so the framing stays
    /// stable for binary-safe documents and a double-newline cannot
    /// slip into the wire.
    ///
    /// The implementation reserves the exact capacity needed up
    /// front so the body's underlying storage is allocated once
    /// per call rather than re-grown on each `append`.
    static func make(document: Data) -> Data {
        let needsTrailingNewline = document.last != 0x0A
        let trailingNewlineCount = needsTrailingNewline ? 1 : 0
        var body = Data()
        body.reserveCapacity(
            actionLineData.count + 1 + document.count + trailingNewlineCount
        )
        body.append(actionLineData)
        body.append(0x0A)
        body.append(document)
        if needsTrailingNewline {
            body.append(0x0A)
        }
        return body
    }

    /// Builds the NDJSON body for a batch of encoded documents
    /// targeting `indexName`. Each document is preceded by its own
    /// `{"create":{"_index":"<indexName>"}}` action line and
    /// followed by a single terminating newline. The whole-body
    /// framing is `<action_1>\n<doc_1>\n<action_2>\n<doc_2>\n…`.
    ///
    /// The action line is built through `JSONSerialization` rather
    /// than string interpolation so an `indexName` containing
    /// quote, backslash, newline, or non-ASCII bytes can never
    /// break NDJSON framing. The hot path encodes the action once
    /// per `make` call and appends the encoded bytes verbatim for
    /// every document.
    ///
    /// Same trailing-newline contract per document as
    /// ``make(document:)``: documents that already end with `0x0A`
    /// keep their existing newline, never doubled.
    ///
    /// Reserved capacity is computed exactly so the body's
    /// underlying storage is allocated once.
    ///
    /// Throws whatever `JSONSerialization.data(withJSONObject:)`
    /// raises — caller (the Elastic adapter) routes the throw
    /// through `RemoteTransport.classify(_:)` as a whole-batch
    /// failure.
    static func make(documents: [Data], indexName: String) throws -> Data {
        let actionDictionary: [String: Any] = [
            ElasticBulkAction.create.rawValue: ["_index": indexName]
        ]
        let actionLineBytes = try JSONSerialization.data(withJSONObject: actionDictionary)
        let totalCapacity = documents.reduce(0) { running, document in
            let documentTrailingNewline = document.last == 0x0A ? 0 : 1
            return running + actionLineBytes.count + 1 + document.count + documentTrailingNewline
        }
        var body = Data()
        body.reserveCapacity(totalCapacity)
        for document in documents {
            body.append(actionLineBytes)
            body.append(0x0A)
            body.append(document)
            if document.last != 0x0A {
                body.append(0x0A)
            }
        }
        return body
    }
}
