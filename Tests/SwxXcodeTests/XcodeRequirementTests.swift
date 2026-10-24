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
