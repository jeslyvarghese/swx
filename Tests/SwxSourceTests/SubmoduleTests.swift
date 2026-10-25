import Foundation
import SwxCore
@testable import SwxSource
import Testing

struct SubmoduleTests {
    // MARK: .gitmodules

    @Test func readsDeclaredModulesInOrder() {
        let output = """
        submodule.vendor/b.path vendor/b
        submodule.vendor/b.url https://example.com/b.git
        submodule.a.path External/a
        submodule.a.url ../a.git
        """
        let modules = GitRepository.parseModules(output)
        #expect(modules.map(\.path) == ["vendor/b", "External/a"])
        #expect(modules.map(\.url) == ["https://example.com/b.git", "../a.git"])
    }

    @Test func skipsModulesOptedOutOfUpdates() {
        let output = """
        submodule.docs.path docs
        submodule.docs.url https://example.com/docs.git
        submodule.docs.update none
        submodule.lib.path lib
        submodule.lib.url https://example.com/lib.git
        """
        #expect(GitRepository.parseModules(output).map(\.path) == ["lib"])
    }

    @Test func readsOnlyGitlinks() {
        let output = "160000 commit 1111111111111111111111111111111111111111\tExternal/a\0"
            + "100644 blob 2222222222222222222222222222222222222222\tREADME.md\0"
            + "160000 commit 3333333333333333333333333333333333333333\tpath with spaces\0"
        #expect(GitRepository.parseGitlinks(output) == [
            "External/a": "1111111111111111111111111111111111111111",
            "path with spaces": "3333333333333333333333333333333333333333",
        ])
    }

    // MARK: Relative URLs (resolved like `git submodule`)

    @Test func resolvesRelativeURLsAgainstTheParent() {
        let parent = "https://github.com/org/repo.git"
        #expect(GitRepository.resolveSubmoduleURL("../other.git", relativeTo: parent) == "https://github.com/org/other.git")
        #expect(GitRepository.resolveSubmoduleURL("../../elsewhere/x", relativeTo: parent) == "https://github.com/elsewhere/x")
        #expect(GitRepository.resolveSubmoduleURL("./sub", relativeTo: parent) == "https://github.com/org/repo.git/sub")
        #expect(GitRepository.resolveSubmoduleURL("https://example.com/a.git", relativeTo: parent) == "https://example.com/a.git")
    }

    @Test func resolvesRelativeURLsForSCPStyleParents() {
        #expect(GitRepository.resolveSubmoduleURL("../other.git", relativeTo: "git@github.com:org/repo.git") == "git@github.com:org/other.git")
        #expect(GitRepository.resolveSubmoduleURL("../../x.git", relativeTo: "git@github.com:org/repo.git") == "git@github.com:x.git")
    }
}

struct PackageKindTests {
    /// SwiftPM records file URLs and absolute paths as local repositories, by path.
    @Test func classifiesSourceControlLocations() {
        #expect(PackageKind.sourceControl(location: "file:///repos/pkg.git") == .localSourceControl(path: "/repos/pkg.git"))
        #expect(PackageKind.sourceControl(location: "/repos/pkg.git") == .localSourceControl(path: "/repos/pkg.git"))
        #expect(PackageKind.sourceControl(location: "https://github.com/a/b") == .remoteSourceControl(url: "https://github.com/a/b"))
        #expect(PackageKind.sourceControl(location: "git@github.com:a/b.git") == .remoteSourceControl(url: "git@github.com:a/b.git"))
        #expect(PackageKind.sourceControl(location: "../relative") == nil)
    }
}

struct LFSTests {
    private func tree(attributes: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("swx-lfs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(attributes.utf8).write(to: root.appendingPathComponent(".gitattributes"))
        return root
    }

    /// Same rule as SwiftPM: a non-comment line with `filter=lfs`.
    @Test func detectsLFSTrackedTrees() throws {
        let tracked = try self.tree(attributes: "*.bin filter=lfs diff=lfs merge=lfs -text\n")
        let commented = try self.tree(attributes: "# *.bin filter=lfs\n*.txt text\n")
        defer {
            try? FileManager.default.removeItem(at: tracked)
            try? FileManager.default.removeItem(at: commented)
        }

        #expect(GitRepository.tracksLFS(tracked))
        #expect(!GitRepository.tracksLFS(commented))
        #expect(!GitRepository.tracksLFS(FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")))
    }

    @Test func parsesLFSFileListing() {
        let oid = String(repeating: "a", count: 64)
        let files = GitRepository.parseLFSFiles("\(oid) * Sources/Kit/Resources/data file.bin\n")
        #expect(files.map(\.oid) == [oid])
        #expect(files.map(\.path) == ["Sources/Kit/Resources/data file.bin"])
    }
}

struct GitHTTPTests {
    @Test func encodesPacketLines() {
        #expect(GitHTTP.packetLine("command=ls-refs\n") == "0014command=ls-refs\n")
        #expect(GitHTTP.packetLine("") == "0004")
    }

    @Test func derivesUploadPackEndpoints() {
        #expect(GitHTTP.endpoint(for: "https://github.com/apple/swift-nio")?.absoluteString == "https://github.com/apple/swift-nio.git/git-upload-pack")
        #expect(GitHTTP.endpoint(for: "https://github.com/apple/swift-nio.git/")?.absoluteString == "https://github.com/apple/swift-nio.git/git-upload-pack")
        // SSH, plain HTTP and embedded credentials stay with git.
        #expect(GitHTTP.endpoint(for: "git@github.com:apple/swift-nio.git") == nil)
        #expect(GitHTTP.endpoint(for: "http://example.com/a.git") == nil)
        #expect(GitHTTP.endpoint(for: "https://user:token@example.com/a.git") == nil)
    }

    /// Annotated tags resolve to their commit (`peeled:`), like `ls-remote`'s `^{}` lines.
    @Test func parsesRefListings() throws {
        let lightweight = String(repeating: "a", count: 40)
        let tag = String(repeating: "b", count: 40)
        let commit = String(repeating: "c", count: 40)
        let body = GitHTTP.packetLine("\(lightweight) refs/tags/1.0.0\n")
            + GitHTTP.packetLine("\(tag) refs/tags/2.0.0 peeled:\(commit)\n") + "0000"
        let tags = try #require(GitHTTP.parse(Data(body.utf8)))
        #expect(tags == [RemoteTag(name: "1.0.0", revision: lightweight), RemoteTag(name: "2.0.0", revision: commit)])
        #expect(GitHTTP.parse(Data("<html>login</html>".utf8)) == nil)
    }
}
