import Foundation

/// The destination an ``ElasticLogger`` writes encoded ECS records
/// to, plus the credentials needed to reach it.
///
/// `ElasticEndpoint` has two cases that correspond to two distinct
/// deployment shapes; pick the one that matches your trust model.
///
/// ## ``ElasticEndpoint/elasticsearch(url:apiKey:)``
///
/// Direct delivery to an Elasticsearch or Elastic Cloud cluster. The
/// adapter appends `/_bulk` to `url` and sends the configured API
/// key in an `Authorization: ApiKey <key>` header on every request.
///
/// This mode is a supported, informed opt-in. **An API key compiled
/// into a client app binary is extractable**: anyone with the binary
/// can recover the key with standard reverse-engineering tooling, so
/// the cluster behind that key inherits the trust level of the
/// distribution channel. Direct mode is appropriate for trial setups,
/// smoke tests, internal-only apps, prototypes, and any context where
/// the operator has consciously accepted that risk. For hardened
/// production use cases the recommended shape is ``intake(url:authorizationHeader:)``
/// (or another intermediary you control), so the real cluster
/// credential never ships with the client.
///
/// ## ``ElasticEndpoint/intake(url:authorizationHeader:)``
///
/// Delivery through a first-party intake / proxy / gateway endpoint
/// owned by the consumer. The adapter sends the encoded ECS record
/// to `url` verbatim -- it does **not** append `/_bulk` -- and lets
/// the intake decide its own URL conventions, indexing, rate
/// limiting, and onward routing to Elasticsearch.
///
/// `authorizationHeader` is sent verbatim as the value of the
/// `Authorization` request header. Bearer, Basic, custom gateway
/// tokens, or no auth are supported through this case because the
/// intake endpoint is consumer-owned. Pass `nil` to omit the
/// `Authorization` header entirely (for example, when the intake
/// runs on a private network and authenticates by transport-level
/// trust).
public enum ElasticEndpoint: Sendable {
    /// Direct delivery to an Elasticsearch / Elastic Cloud cluster
    /// using an `ApiKey` credential.
    ///
    /// - Parameters:
    ///   - url: The cluster base URL. The adapter appends `/_bulk`
    ///     to this URL on every request.
    ///   - apiKey: The Elasticsearch API key. Sent as
    ///     `Authorization: ApiKey <apiKey>` verbatim. Treat this
    ///     value as extractable when compiled into a client binary.
    case elasticsearch(url: URL, apiKey: String)

    /// Delivery through a consumer-owned intake / proxy / gateway
    /// endpoint.
    ///
    /// - Parameters:
    ///   - url: The intake URL. The adapter sends to this URL
    ///     verbatim and does not mutate the path.
    ///   - authorizationHeader: The full value of the
    ///     `Authorization` header (for example `"Bearer abc"` or
    ///     `"Basic ..."`), or `nil` to omit the header entirely.
    case intake(url: URL, authorizationHeader: String?)
}

extension ElasticEndpoint {
    /// The URL the adapter POSTs encoded records to. Direct mode
    /// appends `/_bulk` to the configured cluster URL; intake mode
    /// returns the configured URL verbatim so the intake decides
    /// its own URL conventions.
    var requestURL: URL {
        switch self {
        case let .elasticsearch(url, _):
            return url.appendingPathComponent("_bulk")
        case let .intake(url, _):
            return url
        }
    }

    /// The value the adapter sends in the `Authorization` request
    /// header, or `nil` to omit the header. Direct mode produces
    /// `"ApiKey <apiKey>"`; intake mode passes the consumer's
    /// header value through verbatim.
    var authorizationHeaderValue: String? {
        switch self {
        case let .elasticsearch(_, apiKey):
            return "ApiKey \(apiKey)"
        case let .intake(_, header):
            return header
        }
    }
}
