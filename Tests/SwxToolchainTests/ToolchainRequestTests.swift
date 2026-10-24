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
