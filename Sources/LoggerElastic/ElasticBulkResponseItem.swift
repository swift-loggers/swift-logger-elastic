import Foundation

/// Supported Elasticsearch `_bulk` actions the adapter recognizes
/// on both the request side (action lines built by the internal
/// NDJSON bulk-body helper) and the response side (per-item entries
/// parsed by the internal bulk response parser).
///
/// Pinning the action set explicitly keeps response parsing
/// deterministic — picking the "first key" of a multi-key action
/// object would depend on dictionary ordering, which Swift does not
/// guarantee — and lets `ElasticItemFailure` carry the originating
/// action so failure diagnostics on permanent rejections preserve
/// the operation the engine attempted.
enum ElasticBulkAction: String, Sendable, Equatable {
    /// `create` — used by the adapter's default action line so the
    /// request also works against an Elasticsearch data stream
    /// where `index` is rejected.
    case create

    /// `index` — direct index operation, recognized on the
    /// response-parsing path so the response model stays symmetric
    /// with the documented `_bulk` envelope; the adapter does not
    /// emit `index` action lines itself.
    case index

    /// `update` — recognized on the response-parsing path for
    /// symmetry with the documented `_bulk` envelope; the adapter
    /// does not emit `update` action lines itself.
    case update

    /// `delete` — recognized on the response-parsing path for
    /// symmetry with the documented `_bulk` envelope; the adapter
    /// does not emit `delete` action lines itself.
    case delete
}

/// Per-item entry projected out of an Elasticsearch `_bulk`
/// response.
///
/// The `_bulk` endpoint returns a top-level JSON object with an
/// `items` array; each entry is a single-key object whose key is
/// the bulk action and whose value carries the per-item status
/// plus an optional `error` sub-object.
/// ``ElasticBulkResponseParser`` projects the action object into
/// this shape and ``ElasticRemoteTransport`` consumes it to decide
/// per-item ``ElasticBulkItemClassification``.
struct ElasticBulkResponseItem: Sendable, Equatable {
    /// Bulk action the response entry describes
    /// (`create` / `index` / `update` / `delete`). Carried so
    /// ``ElasticItemFailure`` can preserve the action that produced
    /// the per-item failure.
    let action: ElasticBulkAction

    /// HTTP-style item status (e.g. `201` for an accepted create,
    /// `429` for a transient overload signal, `400` for a permanent
    /// schema rejection, `409` for a `_bulk create` conflict).
    let status: Int

    /// The `error.type` field from the per-item error sub-object, or
    /// `nil` if the item succeeded or the error object did not carry
    /// a `type`.
    let errorType: String?

    /// Per-item classification computed from `status`. The mapping
    /// is intentionally narrow and adapter-owned: the engine never
    /// inspects HTTP status, vendor body codes, or transport error
    /// types (LGR-5 / LGR-7 / LGR-9).
    var classification: ElasticBulkItemClassification {
        ElasticBulkItemClassification.classify(status: status)
    }
}

/// Adapter-owned per-item classification for an Elasticsearch
/// `_bulk` response entry.
///
/// The classification is consumed by
/// ``ElasticRemoteTransport.sendBatch(_:)`` to project the per-item
/// response into one `Result<RemoteTransportResponse, any Error>`
/// in the same input order, and by
/// ``ElasticRemoteTransport.classify(_:)`` to map that result into a
/// `RemoteDeliveryResult` (`success`, `retryable`, or `terminal`)
/// the remote engine consumes.
///
/// ## Locked policy for `409`
///
/// HTTP status `409` (conflict) on a `_bulk create` operation is
/// classified as `.terminal`. The adapter treats the conflict as a
/// **permanent duplicate / conflict outcome**: the document with
/// that `_id` is already present in the index (the engine never
/// stamps the request with an `_id` itself, so a conflict implies
/// an upstream `_id` collision the adapter cannot resolve by
/// retrying the same payload). The engine MUST NOT retry the item
/// and the adapter MUST NOT silently rewrite the result to
/// `.success`; the host's encoder is responsible for collision-free
/// document identity if it opts into one.
enum ElasticBulkItemClassification: Sendable, Equatable {
    /// Elasticsearch accepted the item. Limited to per-item
    /// status `200` or `201`; no other 2xx is recognized as a
    /// per-item write acceptance.
    case success

    /// Elasticsearch refused the item transiently (e.g. `429`,
    /// `503`, generic `5xx`). The remote engine retries under its
    /// configured `RemoteRetryPolicy`.
    case retryable

    /// Elasticsearch refused the item permanently (e.g. `400` for
    /// mapper parsing exceptions, `409` for `_bulk create`
    /// duplicate-document conflicts, generic `4xx` other than
    /// `429`, or any unrecognized 2xx status such as `202` /
    /// `204` the adapter cannot interpret as a per-item write
    /// acceptance). The remote engine does not retry.
    case terminal

    /// Maps an item-level HTTP status to a classification. Only
    /// `200` and `201` count as success — Elasticsearch's `_bulk`
    /// per-item status surface uses those two codes for accepted
    /// writes, and any other 2xx (`202` / `204` / …) signals a
    /// proxy or upstream behaviour the adapter cannot interpret
    /// as a per-item write acceptance and refuses to classify as
    /// success. `429` and `5xx` are transient (retryable); `409`
    /// is pinned to terminal as a product decision (locked at the
    /// type level — see the type-level doc note); everything else
    /// (other 4xx, unrecognized 2xx, etc.) falls through to
    /// terminal.
    static func classify(status: Int) -> ElasticBulkItemClassification {
        switch status {
        case 200, 201:
            return .success
        case 429, 500 ..< 600:
            return .retryable
        case 409:
            // Locked product decision: `_bulk create` conflict is
            // permanent — the document already exists at that
            // `_id` and the engine cannot resolve it by retrying
            // the same payload. Sibling 4xx values fall through
            // the default `.terminal` branch below; the explicit
            // case exists so the policy is documented at the
            // mapping site, not buried in a default branch.
            return .terminal
        default:
            return .terminal
        }
    }
}

/// Per-item failure carried inside `Result.failure` from
/// ``ElasticRemoteTransport.sendBatch(_:)`` when the Elasticsearch
/// `_bulk` response classified the item as `retryable` or
/// `terminal`. ``ElasticRemoteTransport.classify(_:)`` reads the
/// case to project it into a `RemoteDeliveryResult`. The
/// associated values preserve the originating bulk action, the
/// HTTP-style item status, and the optional `error.type` so
/// failure diagnostics can keep the operation context.
enum ElasticItemFailure: Error, Sendable, Equatable {
    /// Elasticsearch refused the item transiently. The remote engine
    /// retries under its configured `RemoteRetryPolicy`.
    case retryable(action: ElasticBulkAction, status: Int, errorType: String?)

    /// Elasticsearch refused the item permanently. The remote engine
    /// does not retry.
    case terminal(action: ElasticBulkAction, status: Int, errorType: String?)
}

/// Whole-batch failures the Elastic adapter raises from
/// ``ElasticRemoteTransport.sendBatch(_:)``. The engine treats a
/// `sendBatch` throw as a transport-level failure for every item in
/// the call and routes each item through
/// ``ElasticRemoteTransport.classify(_:)`` with this error.
///
/// The taxonomy splits diagnostic surface so callers can distinguish
/// the three failure shapes the response path produces:
/// - an empty response body (no bytes at all),
/// - a non-JSON / unparseable body (parser refused the JSON),
/// - a parseable JSON body whose shape does not match the
///   documented `_bulk` response envelope or per-item layout.
enum ElasticBulkError: Error, Sendable, Equatable {
    /// The response body was empty (zero bytes). The adapter cannot
    /// decide success or failure without a body.
    case emptyBulkResponse

    /// The response body was non-empty but `JSONSerialization`
    /// refused to parse it as JSON.
    case invalidBulkResponseJSON

    /// The response body parsed as JSON but did not match the
    /// documented top-level `_bulk` envelope or per-item shape
    /// (missing `errors`, missing `items`, multi-key item action
    /// object, unsupported action key, etc.).
    case malformedBulkResponse

    /// One item entry in the response carried no recognizable
    /// `status` field. The adapter refuses to guess a status so the
    /// engine fails closed.
    case responseItemMissingStatus

    /// The response's `items` array did not contain exactly one
    /// entry per input batch item. ``ElasticRemoteTransport`` uses
    /// positional correlation to project the response back into
    /// per-input results; a count mismatch is a protocol violation
    /// and the adapter refuses to invent results.
    case responseItemCountMismatch(expected: Int, actual: Int)
}
