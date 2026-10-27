import SwxManifest
import Testing

struct ManifestEditorTests {
    private static let nio = DependencyMatch(identity: "swift-nio", referenceNames: ["swift-nio"])
    private static let parser = DependencyMatch(identity: "swift-argument-parser", referenceNames: ["swift-argument-parser"])

    private static let manifest = """
    // swift-tools-version: 6.0
    import PackageDescription

    let package = Package(
        name: "Sample",
        dependencies: [
            .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
            // Networking.
            .package(url: "https://github.com/apple/swift-nio.git", from: "2.60.0"), // the event loop
        ],
        targets: [
            .executableTarget(name: "App", dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio", condition: .when(platforms: [.linux])),
            ]),
            .testTarget(name: "AppTests", dependencies: ["App", .product(name: "NIOCore", package: "swift-nio")]),
        ]
    )

    """

    /// The declaration, its comment and every product use go; nothing else changes.
    @Test func removesDependencyAndItsProducts() throws {
        let edited = try ManifestEditor.removingDependency(Self.nio, from: Self.manifest)
        #expect(edited == """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Sample",
            dependencies: [
                .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
            ],
            targets: [
                .executableTarget(name: "App", dependencies: [
                    .product(name: "ArgumentParser", package: "swift-argument-parser"),
                ]),
                .testTarget(name: "AppTests", dependencies: ["App"]),
            ]
        )

        """)
    }

    /// One-line arrays lose the element and the comma beside it, first or last.
    @Test func removesFromOneLineArrays() throws {
        let both = #"let package = Package(name: "P", dependencies: [.package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"), .package(path: "../swift-nio")])"#
        #expect(try ManifestEditor.removingDependency(Self.nio, from: both) == #"let package = Package(name: "P", dependencies: [.package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")])"#)
        #expect(try ManifestEditor.removingDependency(Self.parser, from: both) == #"let package = Package(name: "P", dependencies: [.package(path: "../swift-nio")])"#)
    }

    /// A target may name the package by the dependency's `name:` (old manifests).
    @Test func matchesReferenceNames() throws {
        let source = #"let package = Package(name: "P", dependencies: [.package(name: "NIO", url: "https://github.com/apple/swift-nio", from: "2.0.0")], targets: [.target(name: "T", dependencies: [.product(name: "NIO", package: "NIO")])])"#
        let match = DependencyMatch(identity: "swift-nio", referenceNames: ["NIO"])
        #expect(try ManifestEditor.removingDependency(match, from: source) == #"let package = Package(name: "P", dependencies: [], targets: [.target(name: "T", dependencies: [])])"#)
    }

    @Test func refusesWhatItCannotSee() {
        let dynamic = #"let deps: [Package.Dependency] = makeDependencies(); let package = Package(name: "P", dependencies: deps)"#
        #expect(throws: ManifestEditError.self) { try ManifestEditor.removingDependency(Self.nio, from: dynamic) }
    }

    /// Every spelling of a single-version requirement is read and rewritten in place.
    @Test func readsAndRewritesVersions() throws {
        let forms: [(String, RequirementSyntax, String)] = [
            (#"from: "2.60.0""#, .upToNextMajor("2.60.0"), #"from: "3.1.0""#),
            (#"exact: "2.60.0""#, .exact("2.60.0"), #"exact: "3.1.0""#),
            (#".upToNextMajor(from: "2.60.0")"#, .upToNextMajor("2.60.0"), #".upToNextMajor(from: "3.1.0")"#),
            (#".upToNextMinor(from: "2.60.0")"#, .upToNextMinor("2.60.0"), #".upToNextMinor(from: "3.1.0")"#),
            (#".exact("2.60.0")"#, .exact("2.60.0"), #".exact("3.1.0")"#),
        ]
        for (requirement, syntax, rewritten) in forms {
            let source = #"let package = Package(name: "P", dependencies: [.package(url: "https://github.com/apple/swift-nio.git", \#(requirement))])"#
            #expect(ManifestEditor.requirement(of: Self.nio, in: source) == syntax)
            #expect(try ManifestEditor.settingVersion("3.1.0", of: Self.nio, in: source) == source.replacingOccurrences(of: requirement, with: rewritten))
        }
    }

    @Test func leavesRangesAndBranchesAlone() {
        let range = #"let package = Package(name: "P", dependencies: [.package(url: "https://github.com/apple/swift-nio", "2.0.0"..<"3.0.0")])"#
        let branch = #"let package = Package(name: "P", dependencies: [.package(url: "https://github.com/apple/swift-nio", branch: "main")])"#
        #expect(ManifestEditor.requirement(of: Self.nio, in: range) == .range)
        #expect(ManifestEditor.requirement(of: Self.nio, in: branch) == .unversioned)
        #expect(ManifestEditor.requirement(of: Self.parser, in: branch) == nil)
        #expect(throws: ManifestEditError.self) { try ManifestEditor.settingVersion("3.0.0", of: Self.nio, in: range) }
    }
}
