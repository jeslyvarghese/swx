import Foundation
import SwxCore
import SwxSystem

/// SwiftPM dependency mirrors (`swift package config set-mirror`).
///
/// Packages are fetched from the mirror and identified by the mirror's identity, while
/// `Package.resolved` keeps the original location so the lockfile stays portable.
struct DependencyMirrors: Sendable {
    private enum Path {
        static let configuration = ".swiftpm/configuration"
        static let file = "mirrors.json"
    }

    /// `original → mirror`
    private let mirrors: [String: String]
    /// `mirror → original`
    private let originals: [String: String]

    static let none = DependencyMirrors(mirrors: [:])

    init(mirrors: [String: String]) {
        self.mirrors = mirrors
        self.originals = Dictionary(mirrors.map { ($0.value, $0.key) }, uniquingKeysWith: { min($0, $1) })
    }

    /// Shared (`~/.swiftpm`) mirrors overlaid by the package's own (`.swiftpm`).
    static func load(for packageDirectory: URL) -> DependencyMirrors {
        let shared = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(Path.configuration).appendingPathComponent(Path.file)
        let local = packageDirectory.appendingPathComponent(Path.configuration).appendingPathComponent(Path.file)
        let merged = Self.read(shared).merging(Self.read(local)) { $1 }
        return DependencyMirrors(mirrors: merged)
    }

    private struct Stored: Decodable {
        struct Entry: Decodable {
            let mirror: String
            let original: String
        }

        let object: [Entry]
    }

    private static func read(_ url: URL) -> [String: String] {
        guard let data = FileSystem.readIfPresent(url), let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return [:]
        }
        return Dictionary(stored.object.map { ($0.original, $0.mirror) }, uniquingKeysWith: { $1 })
    }

    var isEmpty: Bool {
        self.mirrors.isEmpty
    }

    // MARK: Applying

    /// The reference to fetch: mirror location and mirror identity.
    func effective(_ package: PackageReference) -> PackageReference {
        guard case .remoteSourceControl(let url) = package.kind, let mirror = self.mirrors[url] else {
            return package
        }
        return PackageReference(identity: PackageIdentity(location: mirror), kind: .remoteSourceControl(url: mirror))
    }

    func effective(_ declaration: DependencyDeclaration) -> DependencyDeclaration {
        DependencyDeclaration(package: self.effective(declaration.package), requirement: declaration.requirement)
    }

    /// Where to download from: SwiftPM mirrors binary-target URLs too.
    func location(_ url: String) -> String {
        self.mirrors[url] ?? url
    }

    /// The reference to record in `Package.resolved`: the original location.
    func original(_ package: PackageReference) -> PackageReference {
        guard case .remoteSourceControl(let url) = package.kind, let original = self.originals[url] else {
            return package
        }
        return PackageReference(identity: package.identity, kind: .remoteSourceControl(url: original))
    }
}
