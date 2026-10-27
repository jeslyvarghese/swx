import Foundation
import SwxWorkspace
import Testing

struct PackageDiscoveryTests {
    /// Nested packages count; build output, hidden directories and edited packages don't.
    @Test func findsTheRepositorysPackages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("swx-discovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manifests = [
            "Package.swift",
            "Packages/Core/Package.swift",
            "Packages/Core/Examples/Demo/Package.swift",
            ".build/checkouts/swift-nio/Package.swift",
            ".hidden/Package.swift",
            "Apps/node_modules/x/Package.swift",
            "Packages/Core/.build/checkouts/y/Package.swift",
        ]
        for path in manifests {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("// swift-tools-version: 6.0\n".utf8).write(to: file)
        }

        let found = try PackageDiscovery.packages(under: root).map { PackageDiscovery.relativePath(of: $0, to: root) }
        #expect(found == [".", "Packages/Core", "Packages/Core/Examples/Demo"])
    }

    /// `.swx/workspace.json` picks packages by glob, and leaves some out.
    @Test func honoursTheWorkspaceFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("swx-discovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Package.swift", "Packages/Core/Package.swift", "Packages/UI/Package.swift", "Packages/UI/Examples/Demo/Package.swift", "Tools/Gen/Package.swift"] {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        let configuration = root.appendingPathComponent(".swx/workspace.json")
        try FileManager.default.createDirectory(at: configuration.deletingLastPathComponent(), withIntermediateDirectories: true)

        try Data(#"{"packages": ["Packages/**"], "exclude": ["**/Examples/**"]}"#.utf8).write(to: configuration)
        #expect(try PackageDiscovery.packages(under: root).map { PackageDiscovery.relativePath(of: $0, to: root) } == ["Packages/Core", "Packages/UI"])

        try Data(#"{"exclude": ["Tools/*", "."]}"#.utf8).write(to: configuration)
        #expect(try PackageDiscovery.packages(under: root).map { PackageDiscovery.relativePath(of: $0, to: root) } == ["Packages/Core", "Packages/UI", "Packages/UI/Examples/Demo"])

        try Data(#"{"packages": "Packages"}"#.utf8).write(to: configuration)
        #expect(throws: WorkspaceError.self) { try PackageDiscovery.packages(under: root) }
    }

    /// `swift package edit` checkouts in Packages/ belong to the package that edits them.
    @Test func skipsEditedPackages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("swx-discovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Package.swift", "Packages/swift-nio/Package.swift"] {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        let state = root.appendingPathComponent(".build/workspace-state.json")
        try FileManager.default.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"object": {"dependencies": [{"state": {"name": "edited"}}]}, "version": 7}"#.utf8).write(to: state)

        #expect(try PackageDiscovery.packages(under: root).map { PackageDiscovery.relativePath(of: $0, to: root) } == ["."])
    }
}
