import SwxCore
@testable import SwxXcode
import Testing

struct XcodeRequirementTests {
    private let url = "https://example.com/a.git"

    @Test func mapsVersionKinds() throws {
        #expect(try XcodeProjectReader.requirement(["kind": "upToNextMajorVersion", "minimumVersion": "1.3.0"], url: self.url)
            == .version(.range(VersionRange(Version(1, 3, 0), Version(2, 0, 0)))))
        #expect(try XcodeProjectReader.requirement(["kind": "upToNextMinorVersion", "minimumVersion": "1.5.0"], url: self.url)
            == .version(.range(VersionRange(Version(1, 5, 0), Version(1, 6, 0)))))
        #expect(try XcodeProjectReader.requirement(["kind": "exactVersion", "version": "2.0.1"], url: self.url)
            == .version(.exact(Version(2, 0, 1))))
        #expect(try XcodeProjectReader.requirement(["kind": "versionRange", "minimumVersion": "1.0.0", "maximumVersion": "1.4.0"], url: self.url)
            == .version(.range(VersionRange(Version(1, 0, 0), Version(1, 4, 0)))))
    }

    @Test func mapsUnversionedKinds() throws {
        #expect(try XcodeProjectReader.requirement(["kind": "branch", "branch": "main"], url: self.url) == .branch("main"))
        #expect(try XcodeProjectReader.requirement(["kind": "revision", "revision": "abc"], url: self.url) == .revision("abc"))
    }

    @Test func rejectsUnknownKinds() {
        #expect(throws: XcodeProjectError.self) {
            try XcodeProjectReader.requirement(["kind": "somethingNew"], url: self.url)
        }
    }
}

struct XcodeOriginHashTests {
    private func remote(_ url: String) -> XcodePackageReference {
        XcodePackageReference(location: .remote(url: url), requirement: .unversioned)
    }

    private func local(_ path: String) -> XcodePackageReference {
        XcodePackageReference(location: .local(path: path), requirement: .unversioned)
    }

    /// Declared as log, LocalKit, argument-parser, Zed; Xcode hashed localkit, argument-parser, log, zed.
    @Test func ordersLocationsByIdentity() {
        let content = XcodeProject.originHashContent([
            self.remote("https://github.com/apple/swift-log.git"),
            self.local("/tmp/x/LocalKit"),
            self.remote("https://github.com/apple/swift-argument-parser.git"),
            self.local("/tmp/x/Zed"),
        ])
        #expect(content == "/tmp/x/LocalKit" + "https://github.com/apple/swift-argument-parser.git" + "https://github.com/apple/swift-log.git" + "/tmp/x/Zed")
    }
}
