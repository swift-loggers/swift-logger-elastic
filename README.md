# swift-logger-elastic

Elasticsearch adapter for [`swift-loggers`](https://github.com/swift-loggers),
built on top of
[`swift-loggers/swift-logger`](https://github.com/swift-loggers/swift-logger).

The package ships **two delivery paths** with different durability
contracts. Pick the one that matches your operational requirements.

### Best-effort `ElasticLogger` — in-process buffer

`ElasticLogger` materializes each allowed entry, redacts private
and sensitive content, encodes it through the configured
`ElasticDocumentEncoder` (`DefaultElasticDocumentEncoder` emits
Elastic Common Schema (ECS) JSON), and enqueues the payload to a
bounded in-process FIFO worker for delivery to the configured
`ElasticEndpoint`. Privacy-safe
rendering is applied during materialization, and lazy evaluation
of message and attributes is preserved.
`DefaultElasticDocumentEncoder` maps the seven-severity model to
canonical ECS `log.level` strings; custom encoders are free to
project severity differently. Records that reach Elasticsearch
can be queried there and visualized in Kibana.

**This path is best-effort.** The worker uses a fixed-capacity
buffer (1000 payloads by default) with **drop-newest
(producer-side drop)** semantics: when the buffer is full, new
yields are discarded so memory stays predictable when the network
is slow or offline. The best-effort path has **no retry, no durable
queue, no flush-on-lifecycle hook, and no acknowledgement back to
the caller**; payloads that fail to deliver — HTTP errors,
malformed direct `_bulk` responses / invalid envelopes /
item-count mismatches, top-level `_bulk` error responses,
network timeouts, the device being offline — are dropped on the
floor. The buffer lives only in memory, so reconnecting
(or relaunching the app) does not replay previously failed payloads.
Reach for this path only when the operational contract genuinely is
"fire and forget".

### Durable `ElasticRemoteEngine` — queue + retry + ACK lifecycle

`ElasticRemoteEngine` bridges Elastic delivery onto
`swift-logger-remote`'s durable engine: a persistence-backed
`DurableRemoteQueue`, a batch-round retry budget over the
`RemoteTransport.sendBatch(_:)` primitive, a caller-driven
`flush()` lifecycle, retained export reuse across flush passes,
and the acknowledgement-to-removal lifecycle (no destructive
removal until the engine acknowledges a fully-resolved non-empty
flush pass). The internal Elastic transport adapter builds one
`_bulk` request per dispatched batch round (N documents in one HTTP
request), parses the per-item response, and projects each
`items[i]` outcome to one `Result` in the same input order. The
host wires `flush()` from its own lifecycle hooks (background
notifications, shutdown signals, periodic tasks).

> **`0.1.0` public API surface (final, locked):**
>
> - `ElasticLogger(endpoint:serviceName:minimumLevel:urlSession:encoder:redactor:onDiagnostic:)` —
>   the best-effort path. `encoder` (default
>   `DefaultElasticDocumentEncoder`) and `redactor` (default
>   `DefaultElasticRecordRedactor`) are public customization
>   seams; `onDiagnostic` observes
>   `ElasticLoggerDiagnostic.encodingFailed(_:)` and
>   `ElasticLoggerDiagnostic.bufferOverflow`.
> - `ElasticRemoteEngine.make(_:)` — the durable path. Returns a
>   `Wiring` carrying `DurableRemoteQueue` and `RemoteEngine`.
>   `Configuration` accepts `endpoint`, `indexName`, `queueDirectory`,
>   `exportDirectory`, `RemoteBatchPolicy`, `RemoteRetryPolicy`, and
>   an optional `URLSession` (defaults to `.shared`).
>
> Both paths share `ElasticEndpoint`: direct Elasticsearch /
> Elastic Cloud with an `ApiKey`, or a consumer-owned intake /
> proxy / gateway endpoint with an arbitrary `Authorization`
> header (or none).

Requires Swift 6.0+. iOS 13.4, macOS 10.15.4, tvOS 13.4,
watchOS 6.2, visionOS 1. MIT licensed.

API reference (DocC):
[swift-loggers.github.io/swift-logger-elastic](https://swift-loggers.github.io/swift-logger-elastic/documentation/loggerelastic/).

## Threat model

`ElasticLogger` ships two ``ElasticEndpoint`` cases. Pick the one
that matches your trust model.

### `.elasticsearch(url:apiKey:)` -- direct delivery, informed opt-in

Direct mode POSTs to `<url>/_bulk` with `Authorization: ApiKey <apiKey>`.
This is a **supported informed opt-in**, not a prohibition. An API
key compiled into a client app binary is **extractable** even when
the app uses TLS: HTTPS protects the network hop, not secrets embedded
in the binary. Anyone with the binary can recover the key with
standard reverse-engineering tooling, and the cluster behind that key
inherits the trust level of the distribution channel.

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
limiting, schema evolution, and duplicate suppression policy. The
mobile client only needs to reach the intake URL; the credential
that talks to Elasticsearch never has to leave the server. If
duplicate suppression matters, route through an intake/proxy that
derives a stable `_id` per log entry and writes `_bulk create`
actions with that `_id`. The client must not hold the Elasticsearch
API key or decide idempotency policy.

If you control the entire trust boundary (for example, a back-end
Swift service running inside the same VPC as the cluster), pick
whichever case matches what you actually configured: `.elasticsearch`
if the URL is the cluster and you set the `ApiKey`; `.intake` with
`authorizationHeader: nil` if the URL is your in-VPC sidecar that
authenticates by network position.

## Installation

Add this package, the core `swift-loggers/swift-logger` package
(`LoggerLibrary`), and `swift-loggers/swift-logger-remote` to your
`Package.swift`. All three pin to their `0.1.x` SemVer line
through `.upToNextMinor(from: "0.1.0")` once each has shipped its
`0.1.0` tag. The `LoggerLibrary` umbrella product re-exports the
core abstractions and the companion adapters (`LoggerPrint`,
`LoggerFiltering`, `LoggerNoOp`), and is the recommended import
for consumer code.

```swift
// In your Package.swift:
let package = Package(
    name: "MyApp",
    dependencies: [
        .package(
            url: "https://github.com/swift-loggers/swift-logger-elastic.git",
            .upToNextMinor(from: "0.1.0")
        ),
        .package(
            url: "https://github.com/swift-loggers/swift-logger.git",
            .upToNextMinor(from: "0.1.0")
        ),
        .package(
            url: "https://github.com/swift-loggers/swift-logger-remote.git",
            .upToNextMinor(from: "0.1.0")
        )
    ],
    targets: [
        .target(
            name: "MyApp",
            dependencies: [
                .product(name: "LoggerElastic", package: "swift-logger-elastic"),
                .product(name: "LoggerLibrary", package: "swift-logger"),
                .product(name: "LoggerRemote", package: "swift-logger-remote")
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

`serviceName` is the value passed to the configured
`ElasticDocumentEncoder`; `DefaultElasticDocumentEncoder` emits
it as the ECS `service.name` field on every encoded document, and
custom encoders are free to project or ignore it. `minimumLevel`
is the drop-guard threshold; entries strictly below it (and
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

`urlSession` only controls the underlying network round-trip —
TLS configuration, proxy resolution, request and resource
timeouts, custom protocol handlers. It does **not** influence
retry, batching, backpressure, or drop-newest semantics on the
best-effort `ElasticLogger` path; those stay fixed at the
drop-newest / no-retry / no-durable-queue contract documented
above. The durable `ElasticRemoteEngine` path owns its own
retry / batch / ACK contract through `swift-logger-remote`'s
engine — see [Durable delivery with `ElasticRemoteEngine`](#durable-delivery-with-elasticremoteengine)
below.

### Customizing the best-effort path

The best-effort path locks three public customization seams in
`0.1.0`: the document encoder, the privacy redactor, and the
diagnostic observer. The defaults match the built-in best-effort behaviour
(`DefaultElasticDocumentEncoder` emits ECS JSON,
`DefaultElasticRecordRedactor` enforces the privacy contract with
fail-closed handling of unknown privacy), so existing call sites
continue to behave identically without supplying any of these
parameters.

```swift
import Foundation
import LoggerElastic
import LoggerLibrary

let intakeURL = URL(string: "https://logs.example.com/elastic")!
let logger: any Logger = ElasticLogger(
    endpoint: .intake(url: intakeURL, authorizationHeader: "Bearer demo"),
    serviceName: "demo-ios",
    minimumLevel: .info,
    encoder: DefaultElasticDocumentEncoder(),
    redactor: DefaultElasticRecordRedactor(),
    onDiagnostic: { diagnostic in
        switch diagnostic {
        case let .encodingFailed(error):
            // Route encoder failures to a fallback log channel
            // or a metric. The entry is already dropped at this
            // point; the callback only observes.
            print("ElasticLogger encoding failed: \(error)")
        case .bufferOverflow:
            // The bounded buffer rejected a payload under
            // sustained overload. Drop-newest semantics applied;
            // increment an overflow counter or surface it as a
            // metric.
            print("ElasticLogger buffer overflow (drop-newest)")
        }
    }
)
```

`ElasticDocumentEncoder.encode(_:serviceName:)` is allowed to
throw. The adapter treats a throwing encoder as a best-effort
drop: the failing entry is dropped, the encoder's error is
forwarded through `onDiagnostic` as
`ElasticLoggerDiagnostic.encodingFailed(_:)`, and the logger
keeps processing later entries. `Logger.log` itself stays
synchronous and infallible.

Redaction runs **before** encoding and **before** the worker's
bounded buffer, so plaintext private / sensitive content cannot
leak into the buffer or the encoder even if a custom encoder
later throws. Custom redactors SHOULD remain fail-closed for
unknown privacy so a new privacy case added by a future
`swift-logger` release cannot silently leak through the adapter.

## Durable delivery with `ElasticRemoteEngine`

`ElasticRemoteEngine.make(_:)` returns a `Wiring` carrying a
`DurableRemoteQueue` and a `RemoteEngine` from
`swift-logger-remote`. Hosts enqueue pre-encoded Elasticsearch
`_bulk` document bytes onto the queue and call `engine.flush()`
from their own lifecycle hooks; the engine drives batch rounds
against the internal Elastic transport, applies the configured
retry budget, and acknowledges (removes delivered queue payload
bytes) only when every recovered entry across the pass resolves
as `.success` or `.terminal`.

**Payload contract.** `DurableRemoteQueue.enqueue(_:)` admits a
`RemoteDeliveryEntry` whose `payload` is **opaque pre-encoded
bytes**. For this Elastic wiring those bytes are the **single
Elasticsearch `_bulk` document line** (one JSON object) —
typically an ECS-encoded record built by a host-side encoder.
Neither the engine nor the internal Elastic transport
ECS-encodes upstream log records on the caller's behalf; the
host-side encoder must not include the `_bulk` action line. The
transport's only payload responsibility is to prepend the action
line (`{"create":{"_index":"..."}}`) and frame the per-batch body
as NDJSON.

This durable path does not provide exactly-once indexing. The built-in
direct transport does not stamp a stable `_id`; direct
`.elasticsearch` delivery is simpler, but does not provide duplicate
suppression. Use an `.intake` proxy for production dedupe: the proxy
holds the Elasticsearch API key, derives a stable `_id` per log entry
(for example from service name, queue entry identifier, timestamp, and
payload hash), writes `_bulk create` actions with that `_id`, and
classifies duplicate `409` conflicts as already accepted / terminal
according to its policy.

```swift
import Foundation
import LoggerElastic
import LoggerRemote

let queueDirectory = URL(fileURLWithPath: "/path/to/queue")
let exportDirectory = URL(fileURLWithPath: "/path/to/exports")

let configuration = ElasticRemoteEngine.Configuration(
    endpoint: .intake(
        url: URL(string: "https://logs.example.com/elastic")!,
        authorizationHeader: "Bearer demo-app-token"
    ),
    indexName: "logs-swift-loggers-default",
    queueDirectory: queueDirectory,
    exportDirectory: exportDirectory,
    batchPolicy: try RemoteBatchPolicy.make(maxEntryCount: 100, maxByteCount: 64 * 1024),
    retryPolicy: try RemoteRetryPolicy.make(
        maxAttempts: 3,
        backoff: .exponential(initialSeconds: 0.5, multiplier: 2, capSeconds: 8)
    )
)
let wiring = ElasticRemoteEngine.make(configuration)

// Caller encodes the Elasticsearch `_bulk` document bytes upstream
// of enqueue and hands them to the queue verbatim.
try await wiring.queue.enqueue(RemoteDeliveryEntry(
    identifier: 1,
    payload: Data(#"{"@timestamp":"2026-01-01T00:00:00Z","message":"hello"}"#.utf8)
))

// Host-driven flush. Returns a `RemoteFlushSummary` whose
// `.acknowledgement` reports `.removedDeliveredBytes`,
// `.notAcknowledged`, or `.emptyReleased`.
let summary = try await wiring.engine.flush()
```

Direct (`.elasticsearch`) endpoints get strict per-item `_bulk`
response classification (HTTP `200` / `201` → success — and only
those two 2xx codes; any unrecognized 2xx such as `202` / `204`
falls through to terminal fail-closed; `429` / `5xx` → retryable;
`409` `_bulk create` conflict → terminal; other `4xx` →
terminal). Intake (`.intake`) endpoints get the consumer proxy's
per-item validation and partial-failure responsibility: the
adapter treats every 2xx response as full-batch success for every
input item and does not parse the intake body.

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

## Default ECS encoding

With `DefaultElasticDocumentEncoder`, every allowed entry is
encoded as a single JSON object using the following Elastic
Common Schema fields:

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

On the best-effort path, every encoded document payload is
wrapped in a two-line NDJSON `_bulk` body:

```
{"create":{"_index":"logs-swift-loggers-default"}}
<document JSON>
```

(each line terminated by `\n`). On the best-effort path the
action line targets the built-in direct index
`logs-swift-loggers-default`, which matches
`DefaultElasticDocumentEncoder`'s `event.dataset` value. Custom
best-effort `ElasticDocumentEncoder` implementations reuse the
same built-in direct index and are not required to emit an
`event.dataset` field of their own; hosts that need a different
index target route through an intake endpoint (consumer-owned
proxy) or the durable `ElasticRemoteEngine` configuration
instead. The durable path uses the same per-document NDJSON
framing inside each dispatched batch, but builds one `_bulk`
request per dispatched batch round; its `_index` comes from
`ElasticRemoteEngine.Configuration.indexName` (default:
`logs-swift-loggers-default`). Requests are sent with
`Content-Type: application/x-ndjson`.

The best-effort `ElasticLogger` path delivers one record per `_bulk`
request. The durable `ElasticRemoteEngine` path packs every entry
of a dispatched batch round into one `_bulk` request (N documents,
one HTTP round-trip) and projects the per-`items[i]` response back
into a per-input `Result` in the same order.

The default action line shown above omits `_id`; `409` create
conflicts arise only when an intake/proxy or transport policy stamps
stable document IDs. Direct built-in `.elasticsearch` delivery may
duplicate documents on retry because Elasticsearch assigns IDs when
`_id` is omitted.

The two delivery paths classify direct `.elasticsearch` responses
differently — the best-effort path treats `errors: true` as a whole-send
failure, the durable path classifies per item.

**Best-effort `ElasticLogger`.** The worker POSTs **exactly one**
document per `_bulk` request, so the validator treats the whole
send as either success or failure: a top-level JSON object with a
boolean `errors` field set to `false` **and** an `items` array of
length exactly `1` is a success. `errors: true` (any item-level
failure reported inside the envelope) is treated as a whole-send
failure, and so is an empty body, a non-JSON body, a top-level
JSON array, a missing or non-boolean `errors` field, a missing or
non-array `items` field, or an `items` array whose length is not
`1` (zero-item or multi-item responses do not correlate with the
single-document request the worker sent) — those shapes typically
indicate that an upstream proxy rewrote the response or the URL
did not actually point at an Elasticsearch cluster. Whole-send
failures on the best-effort path are swallowed by the best-effort
worker (no retry, no per-item recovery).

**Durable `ElasticRemoteEngine`.** The parser still requires a
well-formed envelope (top-level object + boolean `errors` + array
`items` with exactly one response item per input item + one recognized
action object per item (`create`, `index`, `update`, or `delete`) +
integer per-item `status`); any structural deviation, including an
item-count mismatch or invalid item shape, surfaces as a
whole-batch `sendBatch` failure that the engine routes through
`RemoteTransport.classify(_:)` for every active item. The `errors`
boolean itself is **not** the delivery decision — `errors: true`
is the normal case for any mixed-outcome batch. Per-item `status`
drives classification: only `200` / `201` map to `.success`; any
unrecognized 2xx (`202` / `204` / …) is treated as a per-item
write the adapter cannot interpret and falls through to
`.terminal` fail-closed; `429` / `5xx` → `.retryable`; `409`
`_bulk create` conflict → `.terminal`; other `4xx` → `.terminal`.
The engine's retry budget covers `.retryable` items across batch
rounds within one flush pass while preserving active-set
ordering; `.terminal` items resolve permanently inside the pass.

For `.intake` endpoints the response body is opaque on **both**
paths and only the HTTP status code matters. The intake proxy owns
per-item validation and any partial-failure response; the core
adapter treats every 2xx response as full-batch success for every
input item and does not parse the intake body.

The internal FIFO queue uses a bounded buffer with **drop-newest**
semantics (`bufferingOldest(capacity)`): when the consumer cannot
keep up (slow network, offline transport), the buffer fills to its
fixed capacity, payloads that have already entered the buffer remain
eligible for transport delivery first inside the in-memory queue, and
later yields are dropped before they ever land. The overflow is the
most recent burst; successful remote delivery is still best-effort.

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

Treat the API key as exposed once it ships in a client binary, even
if every request uses TLS; rotate or revoke it after the smoke test.

## Related packages

- [`swift-loggers/swift-logger`](https://github.com/swift-loggers/swift-logger)
  -- the core ecosystem package. It provides the core logging
  abstractions, along with the built-in companion adapters
  (`LoggerPrint`, `LoggerFiltering`, `LoggerNoOp`) and the
  `LoggerLibrary` umbrella product that re-exports them for
  consumer-facing use.
