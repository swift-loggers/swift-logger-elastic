import Foundation

/// Internal helper that wraps an ECS-encoded document in the
/// two-line NDJSON shape the Elasticsearch `_bulk` endpoint expects:
/// an action line followed by the document, each terminated by a
/// newline (`0x0A`).
///
/// The action line targets the ECS data-streams convention for
/// general-purpose log indices: `logs-<dataset>-default` resolves
/// to `logs-swift-loggers-default`, matching the `event.dataset`
/// field the encoder stamps on every record.
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

    /// Builds the NDJSON body for a single ECS-encoded document.
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
}
