import Foundation
import SwxCore
@testable import SwxSource
import SwxWorkspace
import Testing

/// `workspace-state.json` written by SwiftPM 6.4 for lottie-spm (XCFramework) and
/// SwiftLintPlugins (artifact bundle).
private func swiftPMArtifactsState() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "workspace-state-artifacts", withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private let lottie = PackageReference(identity: PackageIdentity(plain: "lottie-spm"), kind: .remoteSourceControl(url: "https://github.com/airbnb/lottie-spm"))
private let swiftLint = PackageReference(identity: PackageIdentity(plain: "swiftlintplugins"), kind: .remoteSourceControl(url: "https://github.com/SimplyDanny/SwiftLintPlugins"))

struct ArtifactStateTests {
    @Test func readsSwiftPMArtifactEntries() throws {
        let state = try #require(WorkspaceState.decodeIfCompatible(try swiftPMArtifactsState()))
        let key = ManagedArtifact.Key(package: lottie.identity, targetName: "Lottie")

        #expect(state.artifactKeys.count == 2)
        #expect(state.artifact(key)?.source == .remote(
            url: "https://github.com/airbnb/lottie-ios/releases/download/4.5.2/Lottie.xcframework.zip",
            checksum: "92206ff6af80373903767214ac16215838f6da11dedca789c0439299b46b6694"
        ))
    }

    /// Entries swx writes itself must be the bytes SwiftPM writes.
    @Test func writesArtifactEntriesLikeSwiftPM() throws {
        let original = try swiftPMArtifactsState()
        var state = try #require(WorkspaceState.decodeIfCompatible(original))

        try state.setArtifact(ManagedArtifact(
            package: lottie,
            packageName: "Lottie",
            targetName: "Lottie",
            source: .remote(
                url: "https://github.com/airbnb/lottie-ios/releases/download/4.5.2/Lottie.xcframework.zip",
                checksum: "92206ff6af80373903767214ac16215838f6da11dedca789c0439299b46b6694"
            ),
            path: "/private/tmp/Lint/.build/artifacts/lottie-spm/Lottie/Lottie.xcframework",
            kind: .xcframework
        ))
        try state.setArtifact(ManagedArtifact(
            package: swiftLint,
            packageName: "SwiftLintPlugins",
            targetName: "SwiftLintBinary",
            source: .remote(
                url: "https://github.com/realm/SwiftLint/releases/download/0.59.1/SwiftLintBinary.artifactbundle.zip",
                checksum: "b9f915a58a818afcc66846740d272d5e73f37baf874e7809ff6f246ea98ad8a2"
            ),
            path: "/private/tmp/Lint/.build/artifacts/swiftlintplugins/SwiftLintBinary/SwiftLintBinary.artifactbundle",
            kind: .artifactsArchive(types: ["executable"])
        ))

        #expect(try state.encode() == original)
    }
}

struct ArchiveLayoutTests {
    private func makeDirectory(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("swx-archive-\(UUID().uuidString)")
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        return root
    }

    private let xcframeworkPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict><key>AvailableLibraries</key><array/></dict></plist>
    """

    @Test func findsXCFrameworkBelowWrapperDirectory() throws {
        let root = try self.makeDirectory(["Release/Kit.xcframework/Info.plist": self.xcframeworkPlist])
        defer { try? FileManager.default.removeItem(at: root) }

        // SwiftPM strips a single plain wrapper directory.
        let stripped = BinaryArtifactSource.strippingWrapperDirectory(root)
        #expect(stripped.lastPathComponent == "Release")
        #expect(BinaryArtifactSource.derive(in: stripped) == DerivedArtifact(relativePath: "Kit.xcframework", kind: .xcframework))
    }

    @Test func keepsArtifactDirectoryAtTopLevel() throws {
        let root = try self.makeDirectory(["Kit.xcframework/Info.plist": self.xcframeworkPlist])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(BinaryArtifactSource.strippingWrapperDirectory(root) == root)
    }

    @Test func readsArtifactBundleTypes() throws {
        let info = #"{"schemaVersion": "1.0", "artifacts": {"tool": {"type": "executable", "version": "1.0", "variants": []}}}"#
        let root = try self.makeDirectory(["Tool.artifactbundle/info.json": info])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(BinaryArtifactSource.derive(in: root)?.kind == .artifactsArchive(types: ["executable"]))
    }

    @Test func declinesAmbiguousArchives() throws {
        let root = try self.makeDirectory([
            "A.xcframework/Info.plist": self.xcframeworkPlist,
            "B.xcframework/Info.plist": self.xcframeworkPlist,
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(BinaryArtifactSource.derive(in: root) == nil)
    }

    @Test func rejectsLinksEscapingTheArchive() throws {
        let root = try self.makeDirectory(["Kit.xcframework/Info.plist": self.xcframeworkPlist])
        defer { try? FileManager.default.removeItem(at: root) }

        // Links inside the archive are fine (framework `Versions/Current`).
        try FileManager.default.createSymbolicLink(atPath: root.path + "/Kit.xcframework/Current", withDestinationPath: "Info.plist")
        try ArchiveExtraction.validateNoEscapingSymlinks(in: root)

        try FileManager.default.createSymbolicLink(atPath: root.path + "/Kit.xcframework/escape", withDestinationPath: "../../outside")
        #expect(throws: SourceError.self) { try ArchiveExtraction.validateNoEscapingSymlinks(in: root) }
    }
}
