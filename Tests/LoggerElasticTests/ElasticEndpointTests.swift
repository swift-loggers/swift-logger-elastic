import Foundation
import Testing

@testable import LoggerElastic

@Suite("ElasticEndpoint")
struct ElasticEndpointTests {
    // MARK: requestURL

    @Test("Direct endpoint appends /_bulk to the cluster URL")
    func directRequestURLAppendsBulk() throws {
        let cluster = try #require(URL(string: "https://es.example.com"))
        let endpoint = ElasticEndpoint.elasticsearch(url: cluster, apiKey: "k")

        #expect(endpoint.requestURL.absoluteString == "https://es.example.com/_bulk")
    }

    @Test("Direct endpoint appends /_bulk under an existing path")
    func directRequestURLAppendsBulkWithExistingPath() throws {
        let cluster = try #require(URL(string: "https://es.example.com/v1"))
        let endpoint = ElasticEndpoint.elasticsearch(url: cluster, apiKey: "k")

        #expect(endpoint.requestURL.absoluteString == "https://es.example.com/v1/_bulk")
    }

    @Test("Intake endpoint preserves the URL verbatim and never appends /_bulk")
    func intakeRequestURLIsVerbatim() throws {
        let intake = try #require(URL(string: "https://logs.example.com/elastic"))
        let endpoint = ElasticEndpoint.intake(
            url: intake,
            authorizationHeader: "Bearer abc"
        )

        #expect(endpoint.requestURL == intake)
        #expect(!endpoint.requestURL.absoluteString.hasSuffix("/_bulk"))
    }

    // MARK: authorizationHeaderValue

    @Test("Direct endpoint produces an `ApiKey <key>` Authorization value")
    func directAuthorizationHeader() throws {
        let cluster = try #require(URL(string: "https://es.example.com"))
        let endpoint = ElasticEndpoint.elasticsearch(
            url: cluster,
            apiKey: "abc123"
        )

        #expect(endpoint.authorizationHeaderValue == "ApiKey abc123")
    }

    @Test("Intake endpoint passes the Authorization header through verbatim")
    func intakeAuthorizationHeaderPassthrough() throws {
        let intake = try #require(URL(string: "https://logs.example.com"))

        let bearer = ElasticEndpoint.intake(
            url: intake,
            authorizationHeader: "Bearer xyz"
        )
        #expect(bearer.authorizationHeaderValue == "Bearer xyz")

        let basic = ElasticEndpoint.intake(
            url: intake,
            authorizationHeader: "Basic dXNlcjpwYXNz"
        )
        #expect(basic.authorizationHeaderValue == "Basic dXNlcjpwYXNz")

        let custom = ElasticEndpoint.intake(
            url: intake,
            authorizationHeader: "Gateway tok-1"
        )
        #expect(custom.authorizationHeaderValue == "Gateway tok-1")
    }

    @Test("Intake endpoint with nil header omits the Authorization header")
    func intakeNilAuthorizationOmitsHeader() throws {
        let intake = try #require(URL(string: "https://logs.example.com"))
        let endpoint = ElasticEndpoint.intake(
            url: intake,
            authorizationHeader: nil
        )

        #expect(endpoint.authorizationHeaderValue == nil)
    }
}
