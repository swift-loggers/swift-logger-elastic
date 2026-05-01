import Foundation

/// Internal transport seam for the M3.2 delivery pipeline.
///
/// `BulkTransport` is the surface the ``DeliveryWorker`` calls when
/// it has an NDJSON body to send. The worker produces the URL,
/// headers, and body; the transport is responsible for the actual
/// network round-trip and for returning the response body so the
/// worker can inspect it. It is **not** part of the public API in
/// M3.2: the contract for a swappable transport, retry policy,
/// batching, and backpressure is held back until at least M3.3 and
/// a second remote sink can inform the protocol shape.
///
/// The default implementation in production is
/// ``URLSessionBulkTransport``. Tests inject a recorder transport
/// that captures the request without touching the network.
protocol BulkTransport: Sendable {
    /// Sends `body` as the HTTP body of a POST request to `url`
    /// with the supplied `headers`. Implementations should treat
    /// any non-2xx response as a failure and throw.
    ///
    /// - Returns: The response body. Empty when the server returns
    ///   no body or the body cannot be read; never `nil`.
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
    /// reported `"errors": true`, meaning at least one individual
    /// item in the bulk request failed even though the request as
    /// a whole was accepted.
    case bulkItemFailures

    /// The body returned for a direct `_bulk` request did not
    /// match the documented Elasticsearch response shape (empty
    /// body, non-JSON, or JSON without a top-level boolean
    /// `errors` field). This usually means an upstream proxy
    /// rewrote the response or the URL did not actually point at
    /// an Elasticsearch cluster.
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
/// - `"errors": false` together with an `items` array is a
///   successful round-trip and returns without throwing.
/// - `"errors": true` together with an `items` array throws
///   ``BulkTransportError/bulkItemFailures``.
/// - Anything else -- empty body, non-JSON body, non-object JSON
///   top-level (a top-level array, string, number, bool, or null),
///   missing or non-boolean `errors` field, or missing or
///   non-array `items` field -- is treated as a malformed response
///   and throws ``BulkTransportError/malformedBulkResponse``.
///   That shape typically means an upstream proxy rewrote the
///   response, or the URL did not actually point at an
///   Elasticsearch cluster.
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
    guard object["items"] is [Any] else {
        throw BulkTransportError.malformedBulkResponse
    }
    if errors {
        throw BulkTransportError.bulkItemFailures
    }
}
