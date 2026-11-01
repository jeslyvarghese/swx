import SwxManifest
import Testing

/// `swx add` writes the new target dependency in the list's own style.
struct TargetDependencyEditTests {
    private static func adding(to target: String, in source: String) throws -> String? {
        try ManifestEditor.addingTargetDependency(product: "GRDB", package: "grdb.swift", to: target, in: source)
    }

    @Test func singleLineListGetsACommaAndASpace() throws {
        let source = """
        let package = Package(name: "P", targets: [
            .target(name: "Store", dependencies: ["Core", "Catalog"]),
        ])
        """
        let edited = try #require(try Self.adding(to: "Store", in: source))
        #expect(edited.contains(#".target(name: "Store", dependencies: ["Core", "Catalog", .product(name: "GRDB", package: "grdb.swift")]),"#))
    }

    @Test func singleLineTrailingCommaStaysLast() throws {
        let source = #"let package = Package(name: "P", targets: [.target(name: "Store", dependencies: ["Core",])])"#
        let edited = try #require(try Self.adding(to: "Store", in: source))
        #expect(edited.contains(#"dependencies: ["Core", .product(name: "GRDB", package: "grdb.swift"),]"#))
    }

    @Test func multiLineListGetsANewIndentedLine() throws {
        let source = """
        let package = Package(name: "P", targets: [
            .target(
                name: "Store",
                dependencies: [
                    "Core",
                    "Catalog",
                ]
            ),
        ])
        """
        let edited = try #require(try Self.adding(to: "Store", in: source))
        #expect(edited.contains("""
                dependencies: [
                    "Core",
                    "Catalog",
                    .product(name: "GRDB", package: "grdb.swift"),
                ]
        """))
    }

    @Test func multiLineListWithoutTrailingCommaKeepsThatStyle() throws {
        let source = """
        let package = Package(name: "P", targets: [
            .target(
                name: "Store",
                dependencies: [
                    "Core"
                ]
            ),
        ])
        """
        let edited = try #require(try Self.adding(to: "Store", in: source))
        #expect(edited.contains("""
                    "Core",
                    .product(name: "GRDB", package: "grdb.swift")
                ]
        """))
    }

    @Test func emptyListAndMissingArgument() throws {
        let empty = #"let package = Package(name: "P", targets: [.target(name: "Store", dependencies: [])])"#
        #expect(try Self.adding(to: "Store", in: empty)?.contains(#"dependencies: [.product(name: "GRDB", package: "grdb.swift")]"#) == true)

        let none = #"let package = Package(name: "P", targets: [.target(name: "Store", path: "S")])"#
        let noneEdited = try Self.adding(to: "Store", in: none)
        #expect(noneEdited?.contains(#".target(name: "Store", dependencies: [.product(name: "GRDB", package: "grdb.swift")], path: "S")"#) == true, "\(String(describing: noneEdited))")

        let multiLine = """
        let package = Package(name: "P", targets: [
            .target(
                name: "Store"
            ),
        ])
        """
        let edited = try #require(try Self.adding(to: "Store", in: multiLine))
        #expect(edited.contains("""
                name: "Store",
                dependencies: [.product(name: "GRDB", package: "grdb.swift")]
        """))
    }

    @Test func otherTargetsAndComputedTargetsAreLeftToSwiftPM() throws {
        let source = #"let package = Package(name: "P", targets: [.target(name: "Core"), .testTarget(name: "StoreTests")])"#
        #expect(try Self.adding(to: "Store", in: source) == nil)

        let computed = #"let names = ["Store"]; let package = Package(name: "P", targets: names.map { .target(name: $0) })"#
        #expect(try Self.adding(to: "Store", in: computed) == nil)
    }
}
