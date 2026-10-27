import Foundation
import SwxSource
@testable import SwxWorkspace
import Testing

struct BuildCacheTests {
    /// A package with a lockfile and one source file, in a fresh directory with its own store.
    private struct Fixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var package: URL { self.base.appendingPathComponent("package") }
        var build: URL { self.package.appendingPathComponent(".build") }

        func make() throws -> Workspace {
            let sources = self.package.appendingPathComponent("Sources/App")
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            try Data("// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"App\")\n".utf8).write(to: self.package.appendingPathComponent("Package.swift"))
            try Data(#"{"pins": [], "version": 2}"#.utf8).write(to: self.package.appendingPathComponent("Package.resolved"))
            try self.write("print(1)\n", to: "Sources/App/main.swift")
            let options = WorkspaceOptions(root: .package(self.package), cacheDirectory: self.base.appendingPathComponent("store"), maximumConcurrency: 2, verbosity: .quiet)
            return Workspace(options: options)
        }

        func write(_ text: String, to path: String) throws {
            let file = self.package.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }

        func exists(_ path: String) -> Bool {
            FileManager.default.fileExists(atPath: self.package.appendingPathComponent(path).path)
        }

        func remove() {
            try? FileManager.default.removeItem(at: self.base)
        }
    }

    /// A source edit changes only the exact key; a pin change changes both.
    @Test func keysFollowTheirInputs() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let workspace = try fixture.make()
        let original = try await workspace.buildCacheKeys()

        try fixture.write("print(2)\n", to: "Sources/App/main.swift")
        let edited = try await workspace.buildCacheKeys()
        #expect(edited.exact != original.exact)
        #expect(edited.dependencies == original.dependencies)

        // Build outputs aren't inputs.
        try fixture.write("x", to: ".build/out/App.o")
        #expect(try await workspace.buildCacheKeys() == edited)

        try fixture.write(#"{"pins": [], "version": 3}"#, to: "Package.resolved")
        #expect(try await workspace.buildCacheKeys().dependencies != original.dependencies)
    }

    /// Outputs travel; checkouts and state stay behind; an existing build is never overwritten.
    @Test func roundTripsOutputsOnly() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let workspace = try fixture.make()
        let remote = try RemoteStorages.make(fixture.base.appendingPathComponent("remote").path)

        // Nothing built yet: nothing to push.
        try fixture.write("tree", to: ".build/checkouts/dep/file.swift")
        #expect(try await workspace.pushBuild(to: remote) == .nothingBuilt)

        try fixture.write("object", to: ".build/out/App.o")
        try fixture.write("{}", to: ".build/workspace-state.json")
        guard case .uploaded(let matches, _) = try await workspace.pushBuild(to: remote) else {
            Issue.record("the build wasn't uploaded")
            return
        }
        #expect(matches == [.exact, .dependencies])
        #expect(try await workspace.pushBuild(to: remote) == .alreadyCached)

        // A fresh `.build` with only checkouts gets the outputs back, and nothing else.
        try FileManager.default.removeItem(at: fixture.build)
        try fixture.write("tree", to: ".build/checkouts/kept/file.swift")
        guard case .restored(.exact, _) = try await workspace.pullBuild(from: remote) else {
            Issue.record("the build wasn't restored")
            return
        }
        #expect(fixture.exists(".build/out/App.o"))
        #expect(fixture.exists(".build/checkouts/kept/file.swift"))
        #expect(!fixture.exists(".build/checkouts/dep"))
        #expect(!fixture.exists(".build/workspace-state.json"))
        #expect(try await workspace.pullBuild(from: remote) == .keptLocal)

        // Other sources, same pins: the dependencies archive.
        try FileManager.default.removeItem(at: fixture.build)
        try fixture.write("print(3)\n", to: "Sources/App/main.swift")
        guard case .restored(.dependencies, _) = try await workspace.pullBuild(from: remote) else {
            Issue.record("the dependencies archive wasn't restored")
            return
        }
    }
}
