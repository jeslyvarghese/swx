import SwxCore
import Testing

struct VersionTests {
    @Test func parsesFullVersions() throws {
        let version = try #require(Version("1.2.3-beta.1+build.5"))
        #expect(version.major == 1)
        #expect(version.minor == 2)
        #expect(version.patch == 3)
        #expect(version.prereleaseIdentifiers == ["beta", "1"])
        #expect(version.buildMetadataIdentifiers == ["build", "5"])
        #expect(version.description == "1.2.3-beta.1+build.5")
    }

    @Test(arguments: ["1.2", "1", "1.2.3.4", "a.b.c", "1.2.-3", "", "1.2.3-", "1..3"])
    func rejectsMalformedVersions(_ text: String) {
        #expect(Version(text) == nil)
    }

    /// SwiftPM reads tags leniently: `0.4` is 0.4.0 (swift-subprocess tags like that).
    @Test func parsesTagsWithoutPatch() {
        #expect(Version(tag: "0.4") == Version(0, 4, 0))
        #expect(Version(tag: "v1.2-beta.1") == Version(1, 2, 0, prereleaseIdentifiers: ["beta", "1"]))
        #expect(Version(tag: "1") == nil)
        #expect(Version("0.4") == nil)
    }

    @Test func parsesTagsWithOptionalPrefix() {
        #expect(Version(tag: "v2.0.1") == Version(2, 0, 1))
        #expect(Version(tag: "2.0.1") == Version(2, 0, 1))
        #expect(Version(tag: "release-2.0.1") == nil)
    }

    @Test func ordersBySemVer() throws {
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "2.0.0"]
        let versions = try ordered.map { try #require(Version($0)) }
        #expect(versions == versions.shuffled().sorted())
    }

    @Test func ignoresBuildMetadataForEquality() {
        #expect(Version("1.0.0+a") == Version("1.0.0+b"))
    }
}

struct VersionRangeTests {
    private let oneToTwo = VersionRange(Version(1, 0, 0), Version(2, 0, 0))

    @Test func containsReleasesInRange() {
        #expect(self.oneToTwo.contains(Version(1, 0, 0)))
        #expect(self.oneToTwo.contains(Version(1, 9, 9)))
        #expect(!self.oneToTwo.contains(Version(2, 0, 0)))
        #expect(!self.oneToTwo.contains(Version(0, 9, 0)))
    }

    @Test func excludesPrereleasesFromReleaseRanges() {
        #expect(!self.oneToTwo.contains(Version("1.5.0-beta")!))
        #expect(!self.oneToTwo.contains(Version("2.0.0-beta")!))
    }

    @Test func admitsPrereleasesWhenABoundIsAPrerelease() {
        let range = VersionRange(Version("1.0.0-alpha")!, Version(2, 0, 0))
        #expect(range.contains(Version("1.0.0-beta")!))
        #expect(range.contains(Version("1.5.0-beta")!))
        // Still rejects pre-releases of a release upper bound.
        #expect(!range.contains(Version("2.0.0-beta")!))
    }
}

struct PackageIdentityTests {
    @Test(arguments: [
        ("https://github.com/apple/swift-nio.git", "swift-nio"),
        ("https://github.com/apple/swift-nio", "swift-nio"),
        ("https://github.com/SwiftyJSON/SwiftyJSON.git", "swiftyjson"),
        ("git@github.com:apple/swift-log.git", "swift-log"),
        ("/Users/me/Packages/MyLib/", "mylib"),
    ])
    func computesIdentity(location: String, identity: String) {
        #expect(PackageIdentity(location: location).description == identity)
    }

    @Test func keepsCaseInDefaultName() {
        #expect(PackageReference.remote("https://github.com/SwiftyJSON/SwiftyJSON.git").name == "SwiftyJSON")
    }
}

struct ToolsVersionTests {
    @Test(arguments: [
        ("// swift-tools-version:5.9", "5.9.0"),
        ("// swift-tools-version: 6.0", "6.0.0"),
        ("//swift-tools-version:5.3.1", "5.3.1"),
        ("// swift-tools-version:5.7; (swiftLanguageVersions)", "5.7.0"),
        ("import PackageDescription", "3.1.0"),
    ])
    func parsesComment(line: String, expected: String) {
        #expect(ToolsVersion.parse(manifest: line + "\nimport PackageDescription").description == expected)
    }

    @Test func prefersExactVersionSpecificManifest() {
        let chosen = ToolsVersion.selectManifest(
            fileNames: ["Package.swift", "Package@swift-6.swift", "Package@swift-5.9.swift"],
            current: ToolsVersion(6, 0),
            contentsOf: { _ in "// swift-tools-version:5.9" }
        )
        #expect(chosen == "Package@swift-6.swift")
    }

    @Test func usesNewestCompatibleVersionSpecificManifest() {
        let manifests = [
            "Package.swift": "// swift-tools-version:5.5",
            "Package@swift-5.9.swift": "// swift-tools-version:5.9",
            "Package@swift-7.swift": "// swift-tools-version:7.0",
        ]
        let chosen = ToolsVersion.selectManifest(fileNames: Array(manifests.keys), current: ToolsVersion(6, 1), contentsOf: { manifests[$0] })
        #expect(chosen == "Package@swift-5.9.swift")
    }

    @Test func fallsBackToRegularManifest() {
        let chosen = ToolsVersion.selectManifest(fileNames: ["Package.swift", "README.md"], current: ToolsVersion(6, 0), contentsOf: { _ in "// swift-tools-version:5.9" })
        #expect(chosen == "Package.swift")
    }
}
