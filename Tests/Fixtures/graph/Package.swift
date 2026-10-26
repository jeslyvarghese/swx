// swift-tools-version: 6.1
import PackageDescription

// Exercises what `show-dependencies` and `swx graph` must get right: a conditional trait that
// switches on another conditional trait further down, a branch pin, a path dependency, a
// platform condition and a test target.
let package = Package(
    name: "GraphFixture",
    traits: [
        .default(enabledTraits: ["Streaming"]),
        "Streaming",
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-async-algorithms",
            exact: "1.1.7",
            traits: [.defaults, .trait(name: "UnstableAsyncStreaming", condition: .when(traits: ["Streaming"]))]
        ),
        .package(url: "https://github.com/apple/swift-log", branch: "main"),
        .package(path: "Local"),
    ],
    targets: [
        .executableTarget(name: "App", dependencies: [
            .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            .product(name: "Logging", package: "swift-log", condition: .when(platforms: [.linux, .macOS])),
            "Local",
        ]),
        .testTarget(name: "AppTests", dependencies: ["App"]),
    ]
)
