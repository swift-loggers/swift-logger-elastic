import Foundation

/// Internal HTTP seam shared by the best-effort `ElasticLogger`
/// worker and the `ElasticRemoteTransport` adapter that bridges
/// Elastic delivery onto `swift-logger-remote`'s durable engine.
///
/// Callers produce the URL, headers, and body for one HTTP request
/// (a single-document `_bulk` payload for the best-effort worker,
/// an N-document `_bulk` payload for the batch-aggregating durable
/// transport); the seam is responsible for the network round-trip
/// and for returning the response body so the caller can decide
/// per-item / per-batch classification.
///
/// `BulkTransport` is **not** public API. The production
/// implementation is `URLSessionBulkTransport`; tests inject a
/// recorder that captures the request without touching the
/// network. The package exposes both delivery paths through
/// higher-level public surfaces — `ElasticLogger` for the
/// best-effort path and `ElasticRemoteEngine.make(_:)` for the
/// durable remote-engine path — and neither path requires the
/// caller to wire a `BulkTransport` directly.
protocol BulkTransport: Sendable {
    /// Sends `body` as the HTTP body of a POST request to `url`
    /// with the supplied `headers`. Implementations should throw for
    /// transport-level request failures and non-2xx HTTP responses.
    ///
    /// - Returns: The response body. Empty when the server returns
    ///   no body; never `nil`.
    func send(
        url: URL,
        headers: [String: String],
        body: Data
    ) async throws -> Data
}

/// Errors the default ``URLSessionBulkTransport`` raises when the
/// remote endpoint rejects an NDJSON bulk payload. The conformance
/// to ``Equatable`` lets tests pin specific cases via
/// `#expect(throws: BulkTransportError.<case>)` rather than the
/// looser `#expect(throws: BulkTransportError.self)`.
enum BulkTransportError: Error, Sendable, Equatable {
    /// The HTTP response returned a non-2xx status code.
    case unsuccessfulStatus(Int)

    /// The HTTP response was missing or could not be inspected as
    /// an `HTTPURLResponse`.
    case invalidResponse

    /// The Elasticsearch `_bulk` response returned HTTP 200 but
    /// reported `"errors": true`, meaning Elasticsearch's top-level
    /// bulk-response contract says at least one individual item
    /// failed for the direct best-effort `_bulk` path even though
    /// the request as a whole was accepted.
    case bulkItemFailures

    /// The body returned for a direct `_bulk` request did not
    /// match the documented Elasticsearch response shape: an
    /// empty body, a non-JSON body, JSON without a top-level
    /// boolean `errors` field, a missing or non-array `items`
    /// field, or an `items` array whose length is not `1` (the
    /// best-effort direct path POSTs exactly one document per
    /// request, so any other item count fails closed here). This
    /// usually means an upstream proxy rewrote the response, the
    /// URL did not actually point at an Elasticsearch cluster, or
    /// the server answered a request the best-effort path never
    /// issued.
    case malformedBulkResponse
}

/// Production transport that POSTs the NDJSON body through
/// `URLSession`. Treated as `@unchecked Sendable` because
/// `URLSession` is documented thread-safe and is held immutably
/// here even though Foundation does not declare formal Sendable
/// conformance on the iOS 13 deployment target.
struct URLSessionBulkTransport: BulkTransport, @unchecked Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(
        url: URL,
        headers: [String: String],
        body: Data
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body

        let (responseBody, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BulkTransportError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw BulkTransportError.unsuccessfulStatus(http.statusCode)
        }
        return responseBody
    }
}

/// Inspects an Elasticsearch `_bulk` response body for the direct
/// endpoint case. The `_bulk` endpoint returns HTTP 200 even when
/// individual items fail and signals the partial failure with
/// `"errors": true` at the top level of the JSON response.
///
/// The function is **strict** because a direct request really did
/// hit Elasticsearch's `_bulk` API, which has a documented
/// response shape: a top-level JSON object that always includes a
/// boolean `errors` field and an `items` array.
///
/// The validator checks the top-level response envelope and the
/// item count for the direct best-effort path. Per-item action
/// object shape inside `items` is **not** validated here — that
/// belongs to the durable response parser in
/// ``ElasticBulkResponseParser`` — but the count is, because the
/// best-effort path always POSTs **exactly one** document per
/// `_bulk` request, so a response carrying anything other than one
/// item entry is a protocol violation regardless of the per-item
/// shape.
///
/// - `"errors": false` together with an `items` array of length
///   one is an accepted top-level envelope and returns without
///   throwing.
/// - `"errors": true` together with an `items` array of length
///   one throws ``BulkTransportError/bulkItemFailures``.
/// - Anything else -- empty body, non-JSON body, non-object JSON
///   top-level (a top-level array, string, number, bool, or null),
///   missing or non-boolean `errors` field, missing or non-array
///   `items` field, or an `items` array whose length is not one --
///   is treated as a malformed response and throws
///   ``BulkTransportError/malformedBulkResponse``. That shape
///   typically means an upstream proxy rewrote the response, the
///   URL did not actually point at an Elasticsearch cluster, or
///   the server answered a request the best-effort path never
///   issued.
///
/// The validator is **not** invoked for ``ElasticEndpoint/intake(url:authorizationHeader:)``
/// endpoints, where the response body is opaque by design (a
/// consumer-owned intake proxy is free to return any 2xx body it
/// likes).
func validateElasticBulkResponse(_ data: Data) throws {
    guard !data.isEmpty else {
        throw BulkTransportError.malformedBulkResponse
    }
    let parsed = try? JSONSerialization.jsonObject(with: data)
    guard let object = parsed as? [String: Any] else {
        throw BulkTransportError.malformedBulkResponse
    }
    guard let errors = object["errors"] as? Bool else {
        throw BulkTransportError.malformedBulkResponse
    }
    guard let items = object["items"] as? [Any] else {
        throw BulkTransportError.malformedBulkResponse
    }
    // Best-effort direct path POSTs exactly one document per
    // `_bulk` request; a response items array of any other length
    // does not correlate with the request the worker sent. Refuse
    // fail-closed rather than guess which item is "the" item.
    guard items.count == 1 else {
        throw BulkTransportError.malformedBulkResponse
    }
    if errors {
        throw BulkTransportError.bulkItemFailures
    }
}
