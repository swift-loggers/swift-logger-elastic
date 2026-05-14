import Foundation

/// Internal parser that projects an Elasticsearch `_bulk` response
/// body into an ordered array of ``ElasticBulkResponseItem``.
///
/// The parser is **strict** about the documented `_bulk` response
/// shape — a top-level JSON object with a boolean `errors` field
/// and an `items` array — because a successful HTTP round-trip is
/// not itself proof of delivery: the `_bulk` endpoint returns HTTP
/// `200` even when individual items fail. Failure surface splits
/// along three diagnostic axes:
///
/// - Empty body → ``ElasticBulkError/emptyBulkResponse``.
/// - Non-JSON / unparseable body →
///   ``ElasticBulkError/invalidBulkResponseJSON``.
/// - Parseable JSON whose shape does not match the documented
///   envelope or per-item layout →
///   ``ElasticBulkError/malformedBulkResponse``.
/// - Item without a recognizable `status` →
///   ``ElasticBulkError/responseItemMissingStatus``.
///
/// Each entry inside `items` is a single-key object whose key is
/// the bulk action (`create`, `index`, `update`, `delete`). The
/// parser looks the key up against ``ElasticBulkAction`` rather
/// than picking `values.first`; multi-key item objects and
/// unrecognized actions fail closed as
/// ``ElasticBulkError/malformedBulkResponse``.
enum ElasticBulkResponseParser {
    /// Parses `data` into an ordered array of
    /// ``ElasticBulkResponseItem`` preserving the order of the
    /// `items` array in the response.
    static func parse(_ data: Data) throws -> [ElasticBulkResponseItem] {
        guard !data.isEmpty else {
            throw ElasticBulkError.emptyBulkResponse
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ElasticBulkError.invalidBulkResponseJSON
        }
        guard let object = parsed as? [String: Any] else {
            throw ElasticBulkError.malformedBulkResponse
        }
        guard object["errors"] is Bool else {
            throw ElasticBulkError.malformedBulkResponse
        }
        guard let items = object["items"] as? [Any] else {
            throw ElasticBulkError.malformedBulkResponse
        }
        return try items.map { entry in
            try parseItem(entry)
        }
    }

    /// Projects one entry from the `items` array into an
    /// ``ElasticBulkResponseItem``. Surfaces
    /// ``ElasticBulkError/malformedBulkResponse`` when the entry
    /// is not a single-key object keyed by a supported
    /// ``ElasticBulkAction``, and
    /// ``ElasticBulkError/responseItemMissingStatus`` when the
    /// action object carries no integer `status` field.
    private static func parseItem(_ entry: Any) throws -> ElasticBulkResponseItem {
        guard let actionObject = entry as? [String: Any] else {
            throw ElasticBulkError.malformedBulkResponse
        }
        // The `_bulk` spec admits exactly one action key per item.
        // Multi-key items collapse to the wrong action under
        // dictionary-iteration ordering, so refuse them rather than
        // guessing.
        guard actionObject.count == 1 else {
            throw ElasticBulkError.malformedBulkResponse
        }
        guard let (actionKey, actionValue) = actionObject.first,
              let action = ElasticBulkAction(rawValue: actionKey),
              let actionFields = actionValue as? [String: Any]
        else {
            throw ElasticBulkError.malformedBulkResponse
        }
        guard let status = actionFields["status"] as? Int else {
            throw ElasticBulkError.responseItemMissingStatus
        }
        let errorType: String?
        if let errorObject = actionFields["error"] as? [String: Any] {
            errorType = errorObject["type"] as? String
        } else {
            errorType = nil
        }
        return ElasticBulkResponseItem(
            action: action, status: status, errorType: errorType
        )
    }
}
