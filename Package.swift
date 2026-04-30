// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-logger-elastic",
    platforms: [
        .iOS(.v13),
        .tvOS(.v13),
        .macOS(.v10_15),
        .watchOS(.v6),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "LoggerElastic",
            targets: ["LoggerElastic"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/swift-loggers/swift-logger.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-docc-plugin.git", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "LoggerElastic",
            dependencies: [
                .product(name: "Loggers", package: "swift-logger")
            ]
        ),
        .testTarget(
            name: "LoggerElasticTests",
            dependencies: [
                "LoggerElastic",
                .product(name: "Loggers", package: "swift-logger")
            ]
        )
    ]
)
