// The cache keys on the selected Xcode, which only macOS has.
#if os(macOS)
import Foundation
@testable import SwxBuild
import SwxSystem
import Testing

struct SchemeListCacheTests {
    private static let manifest = "// swift-tools-version: 6.0\n"
    private static let schemes = ["Kit", "Kit-Package"]

    /// A package directory with a manifest, and a DerivedData directory for the cache.
    private func makePackage() throws -> (package: URL, derivedData: URL) {
        let root = try FileSystem.makeTemporaryDirectory(prefix: "scheme-cache")
        let package = root.appendingPathComponent("Kit")
        try FileSystem.createDirectory(package)
        try FileSystem.writeAtomically(Data(Self.manifest.utf8), to: package.appendingPathComponent("Package.swift"))
        return (package, root.appendingPathComponent("DerivedData"))
    }

    @Test func remembersUntilTheManifestChanges() async throws {
        let (package, derivedData) = try self.makePackage()
        defer { try? FileSystem.removeTree(package.deletingLastPathComponent()) }
        let cache = SchemeListCache(derivedData: derivedData)

        // Nothing remembered yet, then the list comes back unchanged.
        #expect(await cache.schemes(directory: package, container: nil) == nil)
        await cache.remember(Self.schemes, directory: package, container: nil)
        #expect(await cache.schemes(directory: package, container: nil) == Self.schemes)

        // An edited manifest (another size) lists again.
        try FileSystem.writeAtomically(Data((Self.manifest + "// edited\n").utf8), to: package.appendingPathComponent("Package.swift"))
        #expect(await cache.schemes(directory: package, container: nil) == nil)
    }

    @Test func aNewSharedSchemeListsAgain() async throws {
        let (package, derivedData) = try self.makePackage()
        defer { try? FileSystem.removeTree(package.deletingLastPathComponent()) }
        let cache = SchemeListCache(derivedData: derivedData)
        await cache.remember(Self.schemes, directory: package, container: nil)

        let schemes = package.appendingPathComponent(".swiftpm/xcode/xcshareddata/xcschemes")
        try FileSystem.createDirectory(schemes)
        try FileSystem.writeAtomically(Data(), to: schemes.appendingPathComponent("Custom.xcscheme"))
        #expect(await cache.schemes(directory: package, container: nil) == nil)
    }

    @Test func workspacesAreAlwaysListed() async throws {
        let (package, derivedData) = try self.makePackage()
        defer { try? FileSystem.removeTree(package.deletingLastPathComponent()) }
        let cache = SchemeListCache(derivedData: derivedData)
        let workspace = package.appendingPathComponent("App.xcworkspace")

        await cache.remember(Self.schemes, directory: package, container: workspace)
        #expect(await cache.schemes(directory: package, container: workspace) == nil)
    }
}
#endif
