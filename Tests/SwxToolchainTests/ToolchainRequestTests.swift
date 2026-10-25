import Foundation
@testable import SwxToolchain
import Testing

private let releases = ["6.2.3", "6.3", "6.3.1", "6.3.3", "6.4", "6.4.1"].map {
    ToolchainRelease(name: $0, tag: "swift-\($0)-RELEASE")
}

struct ToolchainRequestTests {
    @Test(arguments: [
        ("6.3", "6.3.3"),
        ("6.3.1", "6.3.1"),
        ("6.4.0", "6.4"),
        ("6.4", "6.4.1"),
        ("6", "6.4.1"),
        ("latest", "6.4.1"),
        ("swift-6.2.3-RELEASE", "6.2.3"),
    ])
    func matchesRequests(request: String, expected: String) {
        #expect(ToolchainManager.match(request, in: releases)?.name == expected)
    }

    @Test func rejectsUnknownVersions() {
        #expect(ToolchainManager.match("5.11", in: releases) == nil)
    }

    @Test func systemVersionSatisfiesItsRelease() {
        #expect(ToolchainManager.satisfies("6.4", request: "6.4.0"))
        #expect(ToolchainManager.satisfies("6.4.1", request: "6.4"))
        #expect(!ToolchainManager.satisfies("6.4", request: "6.3"))
    }

    @Test func findsNearestSwiftVersionFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = root.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "6.3\n".write(to: root.appendingPathComponent(".swift-version"), atomically: true, encoding: .utf8)
        #expect(ToolchainManager.requestedVersion(from: nested)?.request == "6.3")
    }

    @Test func buildsDownloadURL() throws {
        let url = try ToolchainManager.downloadURL(for: ToolchainRelease(name: "6.4.1", tag: "swift-6.4.1-RELEASE"))
        #if os(macOS)
        #expect(url.absoluteString == "https://download.swift.org/swift-6.4.1-release/xcode/swift-6.4.1-RELEASE/swift-6.4.1-RELEASE-osx.pkg")
        #endif
    }
}

struct SnapshotRequestTests {
    @Test func parsesSnapshotSpellings() throws {
        let main = try #require(SnapshotRequest("main-snapshot"))
        #expect(main.branch == "main" && main.date == nil && main.tag == nil)

        let dated = try #require(SnapshotRequest("6.5-snapshot-2026-10-17"))
        #expect(dated.branch == "6.5" && dated.date == "2026-10-17")

        let tag = try #require(SnapshotRequest("swift-DEVELOPMENT-SNAPSHOT-2026-10-17-a"))
        #expect(tag.branch == "main" && tag.date == "2026-10-17")

        let branchTag = try #require(SnapshotRequest("swift-6.5-DEVELOPMENT-SNAPSHOT-2026-09-01-a"))
        #expect(branchTag.branch == "6.5")

        #expect(SnapshotRequest("6.4.1") == nil)
        #expect(SnapshotRequest("latest") == nil)
    }

    /// Installed snapshots are named by tag; requests match by branch and date.
    @Test func matchesInstalledSnapshots() throws {
        let main = try #require(SnapshotRequest("main-snapshot"))
        #expect(main.matches(installedName: "swift-DEVELOPMENT-SNAPSHOT-2026-10-17-a"))
        #expect(!main.matches(installedName: "swift-6.5-DEVELOPMENT-SNAPSHOT-2026-10-17-a"))
        #expect(!main.matches(installedName: "6.4.1"))

        let dated = try #require(SnapshotRequest("6.5-snapshot-2026-09-01"))
        #expect(dated.matches(installedName: "swift-6.5-DEVELOPMENT-SNAPSHOT-2026-09-01-a"))
        #expect(!dated.matches(installedName: "swift-6.5-DEVELOPMENT-SNAPSHOT-2026-09-02-a"))
        #expect(!ToolchainManager.satisfies("6.4.1", request: "main-snapshot"))
    }
}
