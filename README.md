# swift-logger-elastic

Elasticsearch adapter for [`swift-loggers`](https://github.com/swift-loggers),
built on top of
[`swift-loggers/swift-logger`](https://github.com/swift-loggers/swift-logger).

For each allowed entry the adapter materializes the record, redacts
private and sensitive content, encodes it as Elastic Common Schema
(ECS) JSON, and enqueues the payload to a bounded FIFO worker for
delivery to the configured ``ElasticEndpoint``. Privacy-safe
rendering is applied during materialization, lazy evaluation of
message and attributes is preserved, and the seven-severity model
maps to the canonical ECS `log.level` strings during encoding.
Records that reach Elasticsearch can be queried there and
visualized in Kibana.

**Delivery is best-effort.** The worker uses a fixed-capacity
buffer (1000 payloads by default) with **drop-newest
(producer-side drop)** semantics: when the buffer is full, new
yields are discarded so memory stays predictable when the network
is slow or offline. There is no retry, no durable queue, no
flush-on-lifecycle hook, and no acknowledgement back to the
caller in this release; what the adapter guarantees is that
allowed entries are correctly redacted, encoded, and processed
in arrival order within the bounded buffer, not that any
individual entry reaches Elasticsearch or is delivered in any
particular order downstream of the buffer. **Payloads that fail
to deliver -- HTTP errors, item-level `_bulk` failures, network
timeouts, the device being offline -- are dropped on the floor;
the buffer lives only in memory, so reconnecting (or relaunching
the app) does not replay previously failed payloads.** A public
flush / backpressure / retry surface lands in a follow-up
milestone; the bounded buffer is the only overload-handling
primitive M3.2 ships.

> **Status: M3.2 (this release).**
> Public API: ``ElasticLogger(endpoint:serviceName:minimumLevel:urlSession:)``
> with the ``ElasticEndpoint`` enum carrying the destination plus
> credentials, and `urlSession` defaulting to `URLSession.shared`
> for consumers who do not need a custom networking stack. Two
> delivery modes are supported: direct
> Elasticsearch / Elastic Cloud with an `ApiKey`, and a
> consumer-owned intake / proxy / gateway endpoint with an
> arbitrary `Authorization` header (or none). Entries below the
> configured threshold (and `LoggerLevel.disabled`) are dropped
> without evaluating the message or attributes autoclosures, never
> reach the encoder, and never reach the transport. Allowed
> entries that overflow the internal bounded queue under sustained
> overload are dropped (drop-newest); only entries that survive
> the bounded buffer reach the transport.

Roadmap (not in this release): swappable encoder / redactor
contracts, batching, retry / backoff, flush-on-lifecycle, and a
**public** backpressure / overflow API. The shared remote-adapter
shape will land once it is informed by a second remote sink
(Datadog, Splunk, Loki).

Requires Swift 6.0+. iOS 13, macOS 10.15, tvOS 13, watchOS 6, visionOS 1.
MIT licensed. Pre-release; the first tagged version will be `0.1.0`.

API reference (DocC, generated from `main`):
[swift-loggers.github.io/swift-logger-elastic](https://swift-loggers.github.io/swift-logger-elastic/documentation/loggerelastic/).

## Threat model

`ElasticLogger` ships two ``ElasticEndpoint`` cases. Pick the one
that matches your trust model.

### `.elasticsearch(url:apiKey:)` -- direct delivery, informed opt-in

Direct mode POSTs to `<url>/_bulk` with `Authorization: ApiKey <apiKey>`.
This is a **supported informed opt-in**, not a prohibition. An API
key compiled into a client app binary is **extractable**: anyone
with the binary can recover the key with standard reverse-
engineering tooling, and the cluster behind that key inherits the
trust level of the distribution channel.

Direct mode is appropriate for trial setups, smoke tests against
Elastic Cloud, internal-only apps, prototypes, throwaway exploration,
and any context where the operator has consciously accepted that
risk. It is **not** the recommended shape for an iOS or macOS app
on the public App Store -- use `.intake(...)` instead.

### `.intake(url:authorizationHeader:)` -- consumer-owned proxy / gateway

Intake mode POSTs to `url` verbatim (no path mutation) and sends
the consumer-supplied `Authorization` header value through unchanged.
Bearer, Basic, custom gateway tokens, or no auth are supported
through `.intake(url:authorizationHeader:)` because the intake
endpoint is consumer-owned. This is the recommended hardened-
production shape.

```
mobile / desktop client            first-party intake             Elasticsearch
-------------------------          ------------------             -------------
ElasticLogger                -->   your service              -->  cluster
  POST intake endpoint               - terminates client TLS         - real API key,
  ECS NDJSON body                    - authenticates the app           server-side
                                     - rate-limits / authorizes
                                     - selects index, forwards
                                     - holds the real credential
```

The intake service owns authentication, index routing, rate
limiting, and schema evolution. The mobile client only needs to
reach the intake URL; the credential that talks to Elasticsearch
never has to leave the server.

If you control the entire trust boundary (for example, a back-end
Swift service running inside the same VPC as the cluster), pick
whichever case matches what you actually configured: `.elasticsearch`
if the URL is the cluster and you set the `ApiKey`; `.intake` with
`authorizationHeader: nil` if the URL is your in-VPC sidecar that
authenticates by network position.

## Installation

Add this package and the core `swift-loggers/swift-logger` package
(`LoggerLibrary`) to your `Package.swift`. The `LoggerLibrary`
umbrella product re-exports the core abstractions and the companion
adapters (`LoggerPrint`, `LoggerFiltering`, `LoggerNoOp`), and is
the recommended import for consumer code. The snippets below use
`import LoggerLibrary` to match the dependency declared in the
install snippet.

```swift
// In your Package.swift:
let package = Package(
    name: "MyApp",
    dependencies: [
        .package(url: "https://github.com/swift-loggers/swift-logger-elastic.git", branch: "main"),
        .package(url: "https://github.com/swift-loggers/swift-logger.git", branch: "main")
    ],
    targets: [
        .target(
            name: "MyApp",
            dependencies: [
                .product(name: "LoggerElastic", package: "swift-logger-elastic"),
                .product(name: "LoggerLibrary", package: "swift-logger")
            ]
        )
    ]
)
```

## Usage

A service holds a `Logger`. At startup an `ElasticLogger` is created
with an ``ElasticEndpoint`` and passed in; the same protocol carries
plain strings, privacy-aware interpolation, and structured
attributes.

`serviceName` is the value the encoder stamps as the ECS
`service.name` field on every record. `minimumLevel` is the
drop-guard threshold; entries strictly below it (and
`LoggerLevel.disabled`) are dropped without evaluating the message
or attributes.

### Recommended: intake / proxy mode

```swift
import LoggerElastic
import LoggerLibrary

let appToken = "demo-app-token"
let logger: any Logger = ElasticLogger(
    endpoint: .intake(
        url: URL(string: "https://logs.example.com/elastic")!,
        authorizationHeader: "Bearer \(appToken)"
    ),
    serviceName: "demo-ios",
    minimumLevel: .info
)
```

Pass `authorizationHeader: nil` when the intake authenticates by
transport-level trust (private network, mTLS terminated upstream)
and does not need an `Authorization` header.

### Direct mode (trial / smoke / internal)

```swift
import LoggerElastic
import LoggerLibrary

let elasticApiKey = "your-api-key"
let directLogger: any Logger = ElasticLogger(
    endpoint: .elasticsearch(
        url: URL(string: "https://my-cluster.es.io")!,
        apiKey: elasticApiKey
    ),
    serviceName: "demo-ios",
    minimumLevel: .info
)
```

The adapter appends `/_bulk` to the cluster URL and sends
`Authorization: ApiKey <apiKey>`. Read the threat-model note above
before shipping a binary that contains an API key.

### Custom URLSession

The public initializer accepts an optional `urlSession: URLSession`
parameter (defaults to `URLSession.shared`) so consumers can hand
the adapter a pre-configured session without subclassing or
swapping the transport. Pass a custom `URLSession` when the
deployment requires certificate pinning, mTLS, enterprise proxy
configuration, custom trust handling, a custom `URLProtocol`, or
a controlled timeout policy.

```swift
import LoggerElastic
import LoggerLibrary

let configuration = URLSessionConfiguration.default
configuration.timeoutIntervalForRequest = 30
// configuration.connectionProxyDictionary = [...]
// configuration.urlCredentialStorage = ...
// Plug a custom URLSessionDelegate for cert pinning / mTLS:
// let customSession = URLSession(
//     configuration: configuration,
//     delegate: myPinningDelegate,
//     delegateQueue: nil
// )
let customSession = URLSession(configuration: configuration)

let pinnedLogger: any Logger = ElasticLogger(
    endpoint: .intake(
        url: URL(string: "https://logs.example.com/elastic")!,
        authorizationHeader: "Bearer demo-app-token"
    ),
    serviceName: "demo-ios",
    minimumLevel: .info,
    urlSession: customSession
)
```

`urlSession` only controls the underlying network round-trip --
TLS configuration, proxy resolution, request and resource
timeouts, custom protocol handlers. It does **not** influence
retry, batching, backpressure, drop-newest semantics, or any
other delivery contract M3.2 documents; those stay fixed in this
release.

## Severities

`ElasticLogger.MinimumLevel` exposes the seven severities of the
core `LoggerLevel` model:

| `MinimumLevel` |
|----------------|
| `trace`        |
| `debug`        |
| `info`         |
| `notice`       |
| `warning`      |
| `error`        |
| `critical`     |

`MinimumLevel` is intentionally severity-only. Per the core
`LoggerLevel` contract, `disabled` is a per-message sentinel and is
not a valid threshold value; to turn off logging entirely, use a
logger that drops every entry instead of configuring a threshold.

The default `MinimumLevel` is `warning`, matching
`MinimumLevel.defaultLevel`.

## ECS encoding

Every allowed entry is encoded as a single JSON object using the
following Elastic Common Schema fields:

| Field            | Source                                                |
|------------------|-------------------------------------------------------|
| `@timestamp`     | adapter wall-clock timestamp at materialization time, ISO 8601 UTC with millisecond precision (for example `2026-04-30T12:00:00.123Z`) |
| `log.level`      | `LoggerLevel.rawValue` -- `trace`, `debug`, `info`, `notice`, `warning`, `error`, or `critical` |
| `message`        | redacted message text; private segments become `<private>` and sensitive segments become `<redacted>` |
| `service.name`   | the `serviceName` passed to `ElasticLogger`           |
| `event.dataset`  | the literal string `swift-loggers`                    |
| `logger.domain`  | `LoggerDomain.rawValue`                               |

User attributes are emitted as top-level dotted keys, with their
values encoded as JSON-native types: `LogValue.string` becomes a
JSON string, `.integer` and `.double` become numbers (non-finite
doubles -- `NaN`, `+infinity`, `-infinity` -- are coerced to JSON
`null`), `.bool` becomes a boolean, `.date` becomes the same ISO
8601 string format as `@timestamp`, `.array` and `.object`
recurse, and `.null` becomes JSON `null`. A private attribute's
value is replaced with the literal `"<private>"` and a sensitive
attribute's with `"<redacted>"` before encoding.

If a user attribute's key collides with one of the six reserved
fields above (or with `labels` itself), the attribute is moved
into a nested `labels` object under its original key. The
canonical fields are never overwritten by user attributes:

```json
{
  "@timestamp": "2026-04-30T12:00:00.123Z",
  "log.level": "info",
  "message": "User opened screen",
  "service.name": "demo-ios",
  "event.dataset": "swift-loggers",
  "logger.domain": "Network",
  "labels": {
    "@timestamp": "user-supplied value, kept here instead of overwriting the canonical field"
  }
}
```

Top-level keys are emitted in sorted order so the output is
byte-stable for identical inputs and easy to diff in tests.

## Wire format

Every encoded record is wrapped in a two-line NDJSON `_bulk` body:

```
{"create":{"_index":"logs-swift-loggers-default"}}
<ECS document>
```

(each line terminated by `\n`). The action line targets the
ECS data-streams convention `logs-<event.dataset>-default`, which
resolves to `logs-swift-loggers-default` and matches the
`event.dataset` field stamped on every record. The request is sent
with `Content-Type: application/x-ndjson`.

The adapter delivers one record per `_bulk` request in M3.2 v1.
Batching, retry, flush-on-lifecycle, and a public backpressure
surface land in a follow-up milestone.

For `.elasticsearch` endpoints the adapter validates the response
body strictly against the documented `_bulk` shape: a successful
delivery requires a top-level JSON object with a boolean `errors`
field set to `false` **and** an `items` array. `errors: true`
(item-level failures) is treated as a delivery failure, and so is
an empty body, a non-JSON body, a top-level JSON array, a missing
or non-boolean `errors` field, or a missing or non-array `items`
field -- those shapes typically indicate that an upstream proxy
rewrote the response or the URL did not actually point at an
Elasticsearch cluster. For `.intake` endpoints the response body
is opaque and only the HTTP status code matters, since a
consumer-owned proxy can answer in any 2xx shape it likes.

The internal FIFO queue uses a bounded buffer with **drop-newest**
semantics (`bufferingOldest(capacity)`): when the consumer cannot
keep up (slow network, offline transport), the buffer fills to its
fixed capacity, payloads that have already entered the buffer keep
moving, and later yields are dropped before they ever land. The
oldest entries that are already queued always make it through; the
overflow is the most recent burst.

## Manual smoke test against Elastic Cloud

To validate the direct path against an Elastic Cloud trial:

1. In the Elastic Cloud console, open *Stack Management ->
   Security -> API keys* and create an API key with `write`
   privileges on the `logs-*` data streams. Copy the **encoded**
   key value.
2. Note the deployment's Elasticsearch endpoint URL (looks like
   `https://<deployment>.es.<region>.aws.cloud.es.io`).
3. Configure `ElasticLogger` and emit a few entries:

   ```swift
   import LoggerElastic
   import LoggerLibrary

   let smokeLogger: any Logger = ElasticLogger(
       endpoint: .elasticsearch(
           url: URL(string: "https://my-deployment.es.us-east-1.aws.cloud.es.io")!,
           apiKey: "your-encoded-api-key"
       ),
       serviceName: "smoke-ios",
       minimumLevel: .trace
   )

   smokeLogger.info("Network", "Smoke test \(Date())")
   smokeLogger.error(
       "Auth",
       "Forced failure",
       attributes: [LogAttribute("auth.method", "password")]
   )
   ```
4. In Kibana, open *Discover* and select the
   `logs-swift-loggers-default` data stream. The entries should
   appear within a few seconds, with `service.name = smoke-ios`,
   the seven canonical `log.level` values, and `logger.domain`
   matching the call site.

Treat the API key as exposed once it ships in a client binary;
rotate or revoke it after the smoke test.

## Related packages

- [`swift-loggers/swift-logger`](https://github.com/swift-loggers/swift-logger)
  -- the core ecosystem package. It provides the core logging
  abstractions, along with the built-in companion adapters
  (`LoggerPrint`, `LoggerFiltering`, `LoggerNoOp`) and the
  `LoggerLibrary` umbrella product that re-exports them for
  consumer-facing use.
