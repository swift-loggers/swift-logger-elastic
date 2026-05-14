// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-logger-elastic",
    platforms: [
        // Aligned with `swift-logger-remote` minimums so the
        // `RemoteTransport` adapter can link against the engine.
        .iOS("13.4"),
        .tvOS("13.4"),
        .macOS("10.15.4"),
        .watchOS("6.2"),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "LoggerElastic",
            targets: ["LoggerElastic"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/swift-loggers/swift-logger.git",
            .upToNextMinor(from: "0.1.0")
        ),
        .package(
            url: "https://github.com/swift-loggers/swift-logger-remote.git",
            .upToNextMinor(from: "0.1.0")
        ),
        .package(url: "https://github.com/apple/swift-docc-plugin.git", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "LoggerElastic",
            dependencies: [
                // The library target keeps a minimal dependency on
                // the protocol-only `Loggers` product. The
                // `LoggerLibrary` umbrella is what consumers
                // declare in their own Package.swift (per the
                // install snippet in README), not something this
                // target re-imports for its own use.
                .product(name: "Loggers", package: "swift-logger"),
                .product(name: "LoggerRemote", package: "swift-logger-remote")
            ]
        ),
        .testTarget(
            name: "LoggerElasticTests",
            dependencies: [
                "LoggerElastic",
                .product(name: "Loggers", package: "swift-logger"),
                .product(name: "LoggerRemote", package: "swift-logger-remote")
            ]
        )
    ]
)
