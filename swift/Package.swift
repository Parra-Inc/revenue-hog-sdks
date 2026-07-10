// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RevenueHog",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
    ],
    products: [
        .library(name: "RevenueHog", targets: ["RevenueHog"])
    ],
    targets: [
        .target(name: "RevenueHog", path: "Sources/RevenueHog"),
        .testTarget(
            name: "RevenueHogTests",
            dependencies: ["RevenueHog"],
            path: "Tests/RevenueHogTests"
        ),
    ]
)
