# swift-logger-elastic

Elasticsearch adapter for [`swift-loggers`](https://github.com/swift-loggers),
built on top of
[`swift-loggers/swift-logger`](https://github.com/swift-loggers/swift-logger).

Once the M3.1 encoder and M3.2 delivery pipeline ship, the adapter
will forward entries from the universal `Logger` contract to a
first-party intake / proxy endpoint as ECS-compatible JSON, queryable
in Elasticsearch and Kibana, with lazy evaluation, privacy-safe
rendering, and the seven-severity model preserved end-to-end. Until
then, the M3.0 release ships only the locked public surface and the
drop guard described below; allowed entries are accepted and
discarded with no encoding and no network I/O.

> **Status: M3.0 scaffolding (this release).**
> The public initializer surface and `MinimumLevel` are locked, and
> entries below the configured threshold (and `.disabled`) are
> dropped without evaluating the message or attributes autoclosures.
> Allowed entries are accepted and discarded; nothing is encoded or
> sent on the network yet. Call sites can integrate against the
> stable API today; the encoder and delivery pipeline that fulfill
> the value proposition above land in M3.1 and M3.2.

Planned milestones:

- **M3.1** -- Elastic Common Schema (ECS) JSON encoder. Privacy
  redaction runs before encoding so private and sensitive segments
  never reach the wire as plaintext.
- **M3.2** -- Ordered delivery pipeline that POSTs encoded records
  to the configured intake URL with batching, retry,
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
The M3.2 delivery pipeline will POST encoded records here; the M3.0
scaffold only stores the value. `serviceName` is the value the M3.1
encoder will stamp as the ECS `service.name` field on every emitted
record (use the app or library name, for example `"demo-ios"`); the
M3.0 scaffold stores it verbatim and does not yet read it.
`minimumLevel` is the drop-guard threshold; entries strictly below
it (and `LoggerLevel.disabled`) are dropped without evaluating the
message or attributes.

```swift
import LoggerElastic
import Loggers

let logger: any Loggers.Logger = ElasticLogger(
    intakeURL: URL(string: "https://logs.example.com/elastic")!,
    serviceName: "demo-ios",
    minimumLevel: .info
)
```

> In M3.0, allowed entries are accepted and discarded; no encoding or
> network delivery occurs yet. The encoder lands in M3.1 and the
> ordered delivery pipeline lands in M3.2.

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

## Companion packages

- [`swift-loggers/swift-logger`](https://github.com/swift-loggers/swift-logger)
  -- protocol-only core plus `PrintLogger`, `DomainFilteredLogger`,
  `NoOpLogger`. The `Logger` protocol, `LogMessage`, `LogAttribute`,
  `LoggerLevel`, and `LoggerDomain` are all defined there.
- [`swift-loggers/swift-logger-oslog`](https://github.com/swift-loggers/swift-logger-oslog)
  -- Apple unified logging adapter. Pair it with this package to
  get on-device OSLog plus remote ingestion from the same call sites.
