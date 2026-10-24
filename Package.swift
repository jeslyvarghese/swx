// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "swx",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "swx", targets: ["swx"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto", "3.0.0"..<"5.0.0"),
    ],
    targets: [
        // Executable: thin entry point that hands off to SwxCLI.
        .executableTarget(
            name: "swx",
            dependencies: ["SwxCLI"]
        ),

        // CLI layer: argument parsing and output. Talks only to SwxWorkspace.
        .target(
            name: "SwxCLI",
            dependencies: [
                "SwxCore",
                "SwxWorkspace",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        // Orchestration: resolved file, workspace state, resolution driver.
        .target(
            name: "SwxWorkspace",
            dependencies: ["SwxCore", "SwxResolver", "SwxManifest", "SwxSource", "SwxStore", "SwxSystem"]
        ),

        // Pure PubGrub solver (sans-I/O). Depends only on SwxCore.
        .target(
            name: "SwxResolver",
            dependencies: ["SwxCore"]
        ),

        // Manifest model, dependency pruning, evaluation and cache.
        .target(
            name: "SwxManifest",
            dependencies: ["SwxCore", "SwxStore", "SwxSystem"]
        ),

        // Source providers: the only layer that talks to git or the network.
        .target(
            name: "SwxSource",
            dependencies: ["SwxCore", "SwxStore", "SwxSystem"]
        ),

        // Global content-addressed store and checkout materialization.
        .target(
            name: "SwxStore",
            dependencies: [
                "SwxCore",
                "SwxSystem",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),

        // Process execution and file-system helpers shared by the shell layers.
        .target(
            name: "SwxSystem"
        ),

        // Shared value types. No dependencies, no Foundation.
        .target(
            name: "SwxCore"
        ),

        .testTarget(name: "SwxCoreTests", dependencies: ["SwxCore"]),
        .testTarget(name: "SwxResolverTests", dependencies: ["SwxCore", "SwxResolver"]),
        .testTarget(name: "SwxManifestTests", dependencies: ["SwxCore", "SwxManifest"]),
        .testTarget(name: "SwxWorkspaceTests", dependencies: ["SwxCore", "SwxWorkspace"]),
    ]
)
