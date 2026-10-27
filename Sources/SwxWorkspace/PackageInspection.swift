import Foundation
import SwxCore
import SwxGraph
import SwxManifest
import SwxSource
import SwxSystem

// The report types the CLI uses, so it needs nothing below SwxWorkspace.
public typealias WhyFormat = SwxGraph.WhyFormat
public typealias LicenseFormat = SwxGraph.LicenseFormat
public typealias ImportsFormat = SwxGraph.ImportsFormat
public typealias ImportsReport = SwxGraph.ImportsReport

/// Questions about the resolved graph: `swx why`, `swx licenses`, `swx inspect imports`.
/// Each expects a resolved workspace.
extension Workspace {
    /// Who depends on a package, up to the root.
    public func why(_ name: String, format: WhyFormat) async throws -> String {
        try await self.packageGraph().why(name, format: format)
    }

    /// The license of every dependency, from its license file.
    public func licenses(format: LicenseFormat) async throws -> String {
        let graph = try await self.packageGraph()
        let dependencies = graph.reachablePackages.filter { $0.role == .dependency }.sorted { $0.identity < $1.identity }
        let licenses = dependencies.map { package -> PackageLicense in
            let directory = URL(fileURLWithPath: package.path, isDirectory: true)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            guard let file = LicenseDetector.licenseFile(among: names) else {
                return PackageLicense(identity: package.identity, version: package.pinned, license: nil, file: nil)
            }
            let text = FileSystem.readIfPresent(directory.appendingPathComponent(file)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            return PackageLicense(identity: package.identity, version: package.pinned, license: LicenseDetector.identify(text), file: file)
        }
        return licenses.render(format)
    }

    /// Imports of undeclared modules, and dependencies nothing imports, in the root's targets.
    public func inspectImports() async throws -> ImportsReport {
        let graph = try await self.packageGraph()
        let root = URL(fileURLWithPath: graph.root.path, isDirectory: true)

        // Each target's imports, from its Swift sources (targets without any are left out).
        var imports: [String: Set<String>] = [:]
        for target in graph.root.manifest.targets {
            guard let directory = Self.sourceDirectory(of: target, in: root) else { continue }
            let files = Self.swiftFiles(in: directory)
            guard !files.isEmpty else { continue }
            imports[target.name] = files.reduce(into: Set<String>()) { modules, file in
                guard let data = FileSystem.readIfPresent(file) else { return }
                modules.formUnion(SourceImports.modules(in: String(decoding: data, as: UTF8.self)))
            }
        }
        return graph.inspectImports(imports)
    }

    // MARK: Target sources

    /// SwiftPM's predefined source directories, in the order it searches them.
    private enum PredefinedDirectory {
        static let sources = ["Sources", "Source", "src", "srcs"]
        static let tests = ["Tests"] + Self.sources
        static let plugins = ["Plugins"]
    }

    private static let swiftExtension = "swift"

    /// Where a target's sources are: its `path:`, or `<predefined>/<name>`.
    static func sourceDirectory(of target: Manifest.Target, in package: URL) -> URL? {
        if let path = target.path {
            let directory = package.appendingPathComponent(path, isDirectory: true)
            return FileSystem.isDirectory(directory) ? directory : nil
        }
        let candidates: [String]
        switch target.kind {
        case .test:
            candidates = PredefinedDirectory.tests
        case .plugin:
            candidates = PredefinedDirectory.plugins
        case .regular, .executable, .macro, .system, .binary:
            candidates = PredefinedDirectory.sources
        }
        return candidates.lazy
            .map { package.appendingPathComponent($0, isDirectory: true).appendingPathComponent(target.name, isDirectory: true) }
            .first(where: FileSystem.isDirectory)
    }

    /// Every `.swift` file below `directory`.
    static func swiftFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == Self.swiftExtension }.sorted { $0.path < $1.path }
    }
}

// MARK: - Outdated

public typealias OutdatedFormat = SwxGraph.OutdatedFormat
public typealias OutdatedScope = SwxGraph.OutdatedScope

extension Workspace {
    /// Pinned, wanted and latest versions of every dependency. Expects a resolved workspace.
    public func outdated() async throws -> [OutdatedEntry] {
        let graph = try await self.packageGraph()
        let root = try await self.rootContext()
        let toolchain = try await Toolchain.detect(store: self.store)
        let source = GitSource(store: self.store, maximumConcurrency: self.options.maximumConcurrency)
        let registry = self.registrySource(for: root)
        let requirements = graph.requirements()

        // Every dependency's released versions, listed concurrently (path dependencies have none).
        let dependencies = graph.reachablePackages.filter { $0.role == .dependency }
        let available = try await withThrowingTaskGroup(of: (String, [Version]).self) { group in
            for package in dependencies {
                guard let reference = package.reference else { continue }
                group.addTask {
                    switch reference.kind {
                    case .registry:
                        return (package.identity, try await registry.versions(of: reference.identity))
                    case .remoteSourceControl, .localSourceControl:
                        return (package.identity, try await source.versions(of: reference, toolsVersion: toolchain.toolsVersion).map(\.version))
                    case .fileSystem, .root:
                        return (package.identity, [])
                    }
                }
            }
            return try await group.reduce(into: [String: [Version]]()) { $0[$1.0] = $1.1 }
        }

        return dependencies.sorted { $0.identity < $1.identity }.map { package in
            graph.outdatedEntry(for: package, available: available[package.identity] ?? [], requirements: requirements[package.identity] ?? [])
        }
    }
}

// MARK: - Audit

public typealias AuditFormat = SwxGraph.AuditFormat
public typealias AuditReport = SwxGraph.AuditReport

extension Workspace {
    /// Known vulnerabilities in the pinned versions of every dependency, from OSV.dev (GitHub's
    /// advisory database), with the policy's ignores applied. Expects a resolved workspace.
    public func audit(policy: AuditPolicy) async throws -> AuditReport {
        let graph = try await self.packageGraph()
        let dependencies = graph.reachablePackages.filter { $0.role == .dependency }.sorted { $0.identity < $1.identity }

        // Only released versions of git packages have names OSV knows.
        var checkable: [(package: GraphPackage, name: String, version: String)] = []
        var unchecked: [String] = []
        for package in dependencies {
            guard let version = package.version, let reference = package.reference, Self.isGitPackage(reference),
                  let name = OSV.packageName(forURL: reference.kind.location) else {
                unchecked.append(package.identity)
                continue
            }
            checkable.append((package, name, version))
        }

        // One batch query for the ids, then each advisory's details once.
        let ids = try await OSV.advisoryIDs(for: checkable.map { ($0.name, $0.version) })
        let findings = try await withThrowingTaskGroup(of: (Int, [Advisory]).self) { group in
            for (index, entry) in checkable.enumerated() where !ids[index].isEmpty {
                group.addTask {
                    var advisories: [Advisory] = []
                    for id in ids[index] {
                        advisories.append(try await OSV.advisory(id, packageName: entry.name))
                    }
                    return (index, advisories)
                }
            }
            return try await group.reduce(into: [(Int, [Advisory])]()) { $0.append($1) }
        }

        return AuditReport(
            findings: findings.sorted { $0.0 < $1.0 }.map { index, advisories in
                AuditFinding(package: checkable[index].package.identity, version: checkable[index].version, advisories: advisories)
            },
            checked: checkable.count,
            unchecked: unchecked,
            policy: policy
        )
    }

    private static func isGitPackage(_ reference: PackageReference) -> Bool {
        if case .remoteSourceControl = reference.kind {
            return true
        }
        return false
    }
}
