# swift-logger-elastic

Elasticsearch adapter for [`swift-loggers`](https://github.com/swift-loggers),
built on top of
[`swift-loggers/swift-logger`](https://github.com/swift-loggers/swift-logger).

For each allowed entry the adapter materializes the record,
redacts private and sensitive content, and encodes it as Elastic
Common Schema (ECS) JSON. Privacy-safe rendering is applied
during materialization, and the seven-severity model and lazy
evaluation of message and attributes are preserved. Once M3.2
lands the delivery pipeline, the encoded payload will be POSTed
to a first-party intake / proxy endpoint, where it can be queried
in Elasticsearch and visualized in Kibana.

> **Status: M3.1 (this release).**
> The public initializer surface and `MinimumLevel` are locked.
> Entries below the configured threshold (and `LoggerLevel.disabled`)
> are dropped without evaluating the message or attributes
> autoclosures. Allowed entries are materialized once, redacted, and
> ECS-encoded; the encoded `Data` is intentionally discarded today
> because the network transport lands in M3.2. M3.1 still performs
> no network I/O.

Planned milestones:

- **M3.2** -- Ordered delivery pipeline that POSTs the encoded ECS
  JSON to the configured intake URL with batching, retry,
  flush-on-lifecycle, and bounded backpressure. The universal
  `Logger` contract stays synchronous; ordering is the adapter's
  responsibility, not the call site's.

Requires Swift 6.0+. iOS 13, macOS 10.15, tvOS 13, watchOS 6, visionOS 1.
MIT licensed. Pre-release; the first tagged version will be `0.1.0`.

API reference (DocC, generated from `main`):
[swift-loggers.github.io/swift-logger-elastic](https://swift-loggers.github.io/swift-logger-elastic/documentation/loggerelastic/).

## Threat model

`intakeURL` is a **first-party intake / proxy endpoint** owned by
the consumer of this package, not a direct Elasticsearch endpoint.

Direct Elasticsearch endpoints take server-side API keys, and a
mobile client app cannot hold those keys safely: any binary on a
user device is reverse-engineerable, and a leaked key grants writer
access to the cluster. The adapter therefore deliberately does
**not** accept an `apiKey`, `token`, or generic `headers` argument
in its primary initializer.

The recommended deployment shape -- what the operator should
provision today, and what the completed adapter will use once
M3.2 lands the delivery pipeline -- is:

```
mobile / desktop client            first-party intake             Elasticsearch
-------------------------          ------------------             -------------
ElasticLogger                -->   your service              -->  cluster
  POST intakeURL                     - terminates client TLS         - real API key,
  ECS JSON body                      - authenticates the app           server-side
                                     - rate-limits / authorizes
                                     - selects index, forwards
                                     - holds the real credential
```

The intake service owns authentication, index routing, rate
limiting, and schema evolution. Once the delivery pipeline lands,
the mobile client will only need to reach the intake URL; the
credential that talks to Elasticsearch never has to leave the
server.

If you control the entire trust boundary (for example, a back-end
Swift service running inside the same VPC as the Elasticsearch
cluster), you are still inside the supported model as long as the
intake URL is one you operate. The locked initializer surface
provides no credential, header, or request-mutation hook, so any
authentication for a direct-cluster URL must be supplied outside
this adapter -- for example, via mTLS terminated by a sidecar, a
private network gateway, or another trust boundary in front of the
cluster.

The client is considered an untrusted environment; all credentials,
index selection, and ingestion control remain server-side at the
intake service.

## Installation

```swift
// In your Package.swift:
let package = Package(
    name: "MyApp",
    dependencies: [
        .package(url: "https://github.com/swift-loggers/swift-logger-elastic.git", branch: "main")
    ],
    targets: [
        .target(
            name: "MyApp",
            dependencies: [
                .product(name: "LoggerElastic", package: "swift-logger-elastic")
            ]
        )
    ]
)
```

## Usage

A service holds a `Logger`. At startup an `ElasticLogger` is
created and passed in; the same protocol carries plain strings,
privacy-aware interpolation, and structured attributes.

`intakeURL` configures the first-party intake URL described above.
The M3.2 delivery pipeline will POST encoded records here; the M3.1
release stores the value but does not issue any network requests.
`serviceName` is the value the encoder stamps as the ECS
`service.name` field on every encoded record (use the app or library
name, for example `"demo-ios"`). `minimumLevel` is the drop-guard
threshold; entries strictly below it (and `LoggerLevel.disabled`)
are dropped without evaluating the message or attributes.

```swift
import LoggerElastic
import Loggers

let logger: any Loggers.Logger = ElasticLogger(
    intakeURL: URL(string: "https://logs.example.com/elastic")!,
    serviceName: "demo-ios",
    minimumLevel: .info
)
```

> In M3.1, allowed entries are materialized once, redacted, and
> ECS-encoded; the encoded `Data` is then discarded because the
> network transport lands in M3.2. M3.1 still performs no network I/O.

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

In M3.1, this encoding is performed locally and the resulting
`Data` is discarded; it becomes the on-wire format once M3.2
lands the delivery pipeline.

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

## Companion packages

- [`swift-loggers/swift-logger`](https://github.com/swift-loggers/swift-logger)
  -- protocol-only core plus `PrintLogger`, `DomainFilteredLogger`,
  `NoOpLogger`. The `Logger` protocol, `LogMessage`, `LogAttribute`,
  `LoggerLevel`, and `LoggerDomain` are all defined there.
- [`swift-loggers/swift-logger-oslog`](https://github.com/swift-loggers/swift-logger-oslog)
  -- Apple unified logging adapter. Pair it with this package to
  get on-device OSLog plus remote ingestion from the same call sites.
