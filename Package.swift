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
        .package(url: "https://github.com/swiftlang/swift-syntax", "600.0.0"..<"700.0.0"),
        // Registry signatures (SE-0391): CMS verification, as SwiftPM 6.4 does it.
        .package(url: "https://github.com/apple/swift-certificates", "1.10.1"..<"2.0.0"),
        .package(url: "https://github.com/apple/swift-asn1", "1.0.0"..<"2.0.0"),
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
            dependencies: ["SwxCore", "SwxResolver", "SwxManifest", "SwxGraph", "SwxSource", "SwxStore", "SwxSystem", "SwxXcode", "SwxToolchain", "SwxBuild", "SwxApple", "SwxDevice"]
        ),

        // Package and target graphs, and their printers (pure: `show-dependencies`, `swx graph`).
        .target(
            name: "SwxGraph",
            dependencies: ["SwxCore", "SwxManifest"]
        ),

        // Build drivers: SwiftPM for the host, xcodebuild for Apple platforms (both run swift-build).
        .target(
            name: "SwxBuild",
            dependencies: ["SwxApple", "SwxSystem"]
        ),

        // Apple platforms and destinations (pure model).
        .target(
            name: "SwxApple"
        ),

        // Simulators and devices: the only module that launches apps.
        .target(
            name: "SwxDevice",
            dependencies: ["SwxApple", "SwxSystem"]
        ),

        // Installs and selects Swift toolchains (`.swift-version`).
        .target(
            name: "SwxToolchain",
            dependencies: ["SwxSystem"]
        ),

        // Reads package references and pins from Xcode projects and workspaces.
        .target(
            name: "SwxXcode",
            dependencies: ["SwxCore", "SwxSystem"]
        ),

        // Pure PubGrub solver (sans-I/O). Depends only on SwxCore.
        .target(
            name: "SwxResolver",
            dependencies: ["SwxCore"]
        ),

        // Manifest model, dependency pruning, evaluation and cache.
        .target(
            name: "SwxManifest",
            dependencies: [
                "SwxCore",
                "SwxStore",
                "SwxSystem",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),

        // Source providers: the only layer that talks to git or the network.
        .target(
            name: "SwxSource",
            dependencies: [
                "SwxCore", "SwxStore", "SwxSystem",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
            ]
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
        .testTarget(name: "SwxGraphTests", dependencies: ["SwxCore", "SwxManifest", "SwxGraph"]),
        .testTarget(
            name: "SwxWorkspaceTests",
            dependencies: ["SwxCore", "SwxSource", "SwxWorkspace"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "SwxXcodeTests", dependencies: ["SwxCore", "SwxXcode"]),
        .testTarget(name: "SwxToolchainTests", dependencies: ["SwxToolchain"]),
        .testTarget(name: "SwxAppleTests", dependencies: ["SwxApple", "SwxDevice"]),
        .testTarget(name: "SwxSystemTests", dependencies: ["SwxSystem"]),
        .testTarget(name: "SwxSourceTests", dependencies: ["SwxCore", "SwxSource", "SwxStore"]),
    ]
)
