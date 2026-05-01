import Foundation
import Testing

/// Returns the ECS document line from an NDJSON `_bulk` body
/// (`<action line>\n<document>\n`). Shared by both
/// ``ElasticLoggerTests`` and ``DeliveryWorkerTests`` so the
/// framing-extraction logic lives in one place; either test file
/// previously carried its own copy plus a custom `Data.split`
/// extension. Uses the standard library's
/// `Collection.split(separator:omittingEmptySubsequences:)` rather
/// than a hand-written byte splitter so the helper has no surface
/// area of its own to keep correct.
func ecsDocumentLine(
    from body: Data,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> Data {
    let parts = body.split(separator: 0x0A, omittingEmptySubsequences: true)
    try #require(parts.count == 2, sourceLocation: sourceLocation)
    return Data(parts[1])
}
