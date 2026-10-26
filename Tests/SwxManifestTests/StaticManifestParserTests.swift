import Foundation
import SwxCore
@testable import SwxManifest
import Testing

private let macOS = CompilationEnvironment(
    operatingSystem: "macOS",
    architecture: "arm64",
    importableModules: ["Darwin", "Foundation"],
    unimportableModules: ["Glibc", "FoundationEssentials"],
    compilerVersion: ToolsVersion(6, 4)
)

private func parse(_ body: String, toolsVersion: String = "6.0") -> Manifest? {
    StaticManifestParser.parse("// swift-tools-version:\(toolsVersion)\nimport PackageDescription\n\n" + body, environment: macOS)
}

private func requirement(_ declaration: String) -> Manifest.Dependency.Requirement? {
    parse("let package = Package(name: \"P\", dependencies: [\(declaration)])")?.dependencies.first?.requirement
}

struct StaticManifestParserTests {
    // MARK: Binary targets

    @Test func readsBinaryTargetLocations() throws {
        let manifest = try #require(parse("""
        let artifact = Target.binaryTarget(name: "Lottie", url: "https://example.com/Lottie.xcframework.zip", checksum: "abc")
        let package = Package(name: "P", targets: [artifact, .binaryTarget(name: "Local", path: "Local.xcframework")])
        """))
        #expect(manifest.targets.map(\.binaryLocation) == [
            .remote(url: "https://example.com/Lottie.xcframework.zip", checksum: "abc"),
            .local(path: "Local.xcframework"),
        ])
    }

    @Test func declinesComputedBinaryLocations() {
        #expect(parse("""
        let version = "1.0"
        let package = Package(name: "P", targets: [.binaryTarget(name: "B", url: "https://example.com/\\(version).zip", checksum: "abc")])
        """) == nil)
    }

    // MARK: Requirements

    @Test func readsEveryRequirementSpelling() {
        let url = "url: \"https://github.com/apple/swift-nio.git\""
        #expect(requirement(".package(\(url), from: \"2.0.0\")") == .range(lowerBound: "2.0.0", upperBound: "3.0.0"))
        #expect(requirement(".package(\(url), exact: \"2.1.0\")") == .exact("2.1.0"))
        #expect(requirement(".package(\(url), \"1.0.0\"..<\"1.5.0\")") == .range(lowerBound: "1.0.0", upperBound: "1.5.0"))
        #expect(requirement(".package(\(url), \"1.2.3\"...\"1.2.6\")") == .range(lowerBound: "1.2.3", upperBound: "1.2.7"))
        #expect(requirement(".package(\(url), .upToNextMinor(from: \"1.2.0\"))") == .range(lowerBound: "1.2.0", upperBound: "1.3.0"))
        #expect(requirement(".package(\(url), .upToNextMajor(from: \"1.2.0\"))") == .range(lowerBound: "1.2.0", upperBound: "2.0.0"))
        #expect(requirement(".package(\(url), branch: \"main\")") == .branch("main"))
        #expect(requirement(".package(\(url), revision: \"abc123\")") == .revision("abc123"))
        #expect(requirement(".package(\(url), .branch(\"dev\"))") == .branch("dev"))
        #expect(requirement(".package(\(url), from: Version(1, 2, 3))") == .range(lowerBound: "1.2.3", upperBound: "2.0.0"))
    }

    @Test func computesIdentityAndExplicitName() throws {
        let manifest = try #require(parse("""
        let package = Package(name: "P", dependencies: [
            .package(name: "Yams", url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        ])
        """))
        let dependency = try #require(manifest.dependencies.first)
        #expect(dependency.identity == "yams")
        #expect(dependency.explicitName == "Yams")
        #expect(dependency.traits == ["default"])
    }

    @Test func resolvesPathDependenciesAgainstThePackageDirectory() throws {
        let manifest = try #require(StaticManifestParser.parse(
            "// swift-tools-version:6.0\nimport PackageDescription\nlet package = Package(name: \"P\", dependencies: [.package(path: \"../Local\")])",
            packageDirectory: URL(fileURLWithPath: "/work/app"),
            environment: macOS
        ))
        #expect(manifest.dependencies.first?.location == .local(path: "/work/Local"))
        #expect(manifest.dependencies.first?.identity == "local")
    }

    // MARK: Targets and products

    @Test func readsTargetsProductsAndConditions() throws {
        let manifest = try #require(parse("""
        let package = Package(
            name: "P",
            products: [.library(name: "Lib", targets: ["Lib"])],
            dependencies: [.package(url: "https://example.com/a.git", from: "1.0.0")],
            targets: [
                .target(
                    name: "Lib",
                    dependencies: [
                        "Helpers",
                        .product(name: "A", package: "a", condition: .when(platforms: [.linux])),
                        .product(name: "B", package: "a", condition: .when(traits: ["Fast"])),
                        .target(name: "Core"),
                    ],
                    swiftSettings: [.unsafeFlags(computeFlags())],
                    plugins: [.plugin(name: "Gen", package: "a")]
                ),
                .testTarget(name: "LibTests", dependencies: ["Lib"]),
            ],
            traits: [.default(enabledTraits: ["Fast"]), "Fast"]
        )
        """))
        let target = try #require(manifest.targets.first)
        #expect(target.dependencies == [
            .byName(name: "Helpers", condition: nil),
            .product(name: "A", package: "a", condition: Manifest.Condition(platforms: ["linux"], traits: nil)),
            .product(name: "B", package: "a", condition: Manifest.Condition(traits: ["Fast"])),
            .target(name: "Core", condition: nil),
        ])
        #expect(target.pluginUsages == [Manifest.PluginUsage(name: "Gen", package: "a")])
        #expect(manifest.products == [Manifest.Product(name: "Lib", targets: ["Lib"])])
        #expect(manifest.traits.map(\.name) == ["Fast", "default"])
    }

    /// Platforms are spelled as PackageDescription's `Platform.name`, as `dump-package` prints them.
    @Test func readsPlatformConditions() throws {
        let manifest = try #require(parse("""
        let package = Package(name: "P", targets: [
            .target(name: "Lib", dependencies: [
                .target(name: "A", condition: .when(platforms: [.macOS, Platform.iOS, .visionOS])),
                .target(name: "B", condition: .when(platforms: [.custom("freertos")], traits: ["Fast"])),
                .target(name: "C", condition: .when(platforms: [])),
            ]),
        ])
        """))
        #expect(manifest.targets[0].dependencies.map(\.condition) == [
            Manifest.Condition(platforms: ["macos", "ios", "visionos"], traits: nil),
            Manifest.Condition(platforms: ["freertos"], traits: ["Fast"]),
            Manifest.Condition(platforms: nil, traits: nil),
        ])
    }

    @Test func declinesComputedPlatforms() {
        #expect(parse("""
        let package = Package(name: "P", targets: [
            .target(name: "Lib", dependencies: [.target(name: "A", condition: .when(platforms: hostPlatforms()))]),
        ])
        """) == nil)
    }

    @Test func followsConstantsAndConcatenation() throws {
        let manifest = try #require(parse("""
        let common: [Package.Dependency] = [.package(url: "https://example.com/a.git", from: "1.0.0")]
        let extra = [Package.Dependency.package(url: "https://example.com/b.git", from: "2.0.0")]
        let package = Package(name: "P", dependencies: common + extra)
        """))
        #expect(manifest.dependencies.map(\.identity) == ["a", "b"])
    }

    // MARK: Imperative code

    @Test func replaysPackageMutations() throws {
        let manifest = try #require(parse("""
        let package = Package(name: "P", targets: [.target(name: "A")])
        package.dependencies += [.package(url: "https://example.com/a.git", from: "1.0.0")]
        package.targets.append(.target(name: "B"))
        """))
        #expect(manifest.dependencies.map(\.identity) == ["a"])
        #expect(manifest.targets.map(\.name) == ["A", "B"])
    }

    @Test func evaluatesCompilationConditions() throws {
        let manifest = try #require(parse("""
        let package = Package(name: "P", targets: [.target(name: "A")])
        #if os(Linux) || canImport(Glibc)
        package.targets.append(.target(name: "LinuxOnly"))
        #elseif os(macOS) && compiler(>=6.0)
        package.targets.append(.target(name: "MacOnly"))
        #else
        package.targets.append(.target(name: "Other"))
        #endif
        """))
        #expect(manifest.targets.map(\.name) == ["A", "MacOnly"])
    }

    @Test func tracksVarAppendsBeforeThePackage() throws {
        let manifest = try #require(parse("""
        var targets: [Target] = [.target(name: "A")]
        targets.append(contentsOf: [.target(name: "B")])
        let package = Package(name: "P", targets: targets)
        targets.append(.target(name: "TooLate"))
        """))
        #expect(manifest.targets.map(\.name) == ["A", "B"])
    }

    @Test func treatsSettingsOnlyMapAsIdentity() throws {
        let manifest = try #require(parse("""
        let targets: [Target] = [.target(name: "A")]
        let package = Package(name: "P", targets: targets.map { target in
            target.swiftSettings = (target.swiftSettings ?? []) + [.enableUpcomingFeature("ExistentialAny")]
            return target
        })
        """))
        #expect(manifest.targets.map(\.name) == ["A"])
    }

    @Test func allowsSettingsLoops() {
        let manifest = parse("""
        let package = Package(name: "P", targets: [.target(name: "A")])
        for target in package.targets {
            target.swiftSettings = [.enableExperimentalFeature("StrictConcurrency")]
        }
        """)
        #expect(manifest?.targets.map(\.name) == ["A"])
    }

    @Test func readsAppleProductTypesApplications() throws {
        let manifest = try #require(parse("""
        import AppleProductTypes

        let package = Package(
            name: "HelloApp",
            platforms: [.iOS("17.0")],
            products: [
                .iOSApplication(
                    name: "HelloApp",
                    targets: ["AppModule"],
                    bundleIdentifier: "dev.swx.HelloApp",
                    appIcon: .placeholder(icon: .bunny),
                    supportedDeviceFamilies: [.pad, .phone],
                    supportedInterfaceOrientations: [.portrait]
                ),
            ],
            targets: [.executableTarget(name: "AppModule", path: ".")]
        )
        """))
        let settings = Manifest.Product.ApplicationSettings(
            bundleIdentifier: "dev.swx.HelloApp", teamIdentifier: nil, displayVersion: nil, bundleVersion: nil,
            deviceFamilies: ["pad", "phone"], interfaceOrientations: ["portrait"]
        )
        #expect(manifest.products == [Manifest.Product(name: "HelloApp", targets: ["AppModule"], kind: .application, application: settings)])
    }

    // MARK: Declining (always safe)

    @Test(arguments: [
        // Environment-dependent dependencies.
        """
        let package = Package(name: "P")
        if ProcessInfo.processInfo.environment["CI"] != nil {
            package.dependencies.append(.package(url: "https://example.com/a.git", from: "1.0.0"))
        }
        """,
        // A `var` mutated by opaque code.
        """
        var deps: [Package.Dependency] = []
        if Bool.random() { deps.append(.package(url: "https://example.com/a.git", from: "1.0.0")) }
        let package = Package(name: "P", dependencies: deps)
        """,
        // Undecidable condition.
        """
        let package = Package(name: "P")
        #if canImport(SomethingUnknown)
        package.targets.append(.target(name: "X"))
        #endif
        """,
        // Computed dependencies.
        """
        func dependencies() -> [Package.Dependency] { [] }
        let package = Package(name: "P", dependencies: dependencies())
        """,
        // Unknown import.
        """
        import SomeModule
        let package = Package(name: "P")
        """,
        // Interpolated URL.
        """
        let base = "https://example.com"
        let package = Package(name: "P", dependencies: [.package(url: "\\(base)/a.git", from: "1.0.0")])
        """,
    ])
    func declinesDynamicManifests(_ body: String) {
        #expect(parse(body) == nil)
    }
}
