// swift-tools-version:5.9
// Root manifest so the repo itself is a valid SPM package
// (`.package(url: "https://github.com/Parra-Inc/revenue-hog-sdks", …)`).
// SPM only discovers Package.swift at the repository root; the sources stay
// under swift/ alongside the react-native/ and kotlin/ SDKs, reached via
// explicit target paths.
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
        .target(name: "RevenueHog", path: "swift/Sources/RevenueHog"),
        .testTarget(
            name: "RevenueHogTests",
            dependencies: ["RevenueHog"],
            path: "swift/Tests/RevenueHogTests"
        ),
    ]
)
