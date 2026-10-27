import Foundation
import SwxCore
import SwxManifest
import SwxSource
import SwxSystem

/// What `swx remove` took out of `Package.swift`.
public struct RemoveResult: Sendable {
    public let identity: String
    /// The manifest as it was, to put back if resolving fails.
    public let previousManifest: Data
}

/// One requirement `swx upgrade` moves (or would move) to a newer release.
public struct UpgradeChange: Sendable, Equatable {
    public let identity: String
    public let from: String
    public let to: String
}

/// A dependency `swx upgrade` couldn't move, and why.
public struct UpgradeSkip: Sendable, Equatable {
    public let identity: String
    public let reason: String
}

/// What `swx upgrade` changed, or would change.
public struct UpgradeResult: Sendable {
    public let changes: [UpgradeChange]
    public let skipped: [UpgradeSkip]
    /// The manifest as it was, to put back if resolving fails; `nil` when nothing was written.
    public let previousManifest: Data?
}

/// Whether an edit is written or only reported.
public enum EditEffect: Sendable {
    case apply
    case dryRun
}

extension Workspace {
    /// Removes a dependency and every target's use of its products from `Package.swift`. The
    /// caller resolves afterwards.
    public func remove(_ name: String) async throws -> RemoveResult {
        let (directory, manifest) = try await self.rootManifest()
        let dependency = try Self.dependency(named: name, in: manifest)
        let manifestFile = directory.appendingPathComponent(WellKnownFile.manifest)
        let previous = try FileSystem.read(manifestFile)

        // Targets that name one of its products without `.product(…, package:)` would break.
        let graph = try? await self.packageGraph()
        let package = graph.flatMap { $0.package(satisfying: dependency, declaredBy: $0.root) }
        let products = Set(package?.manifest.products.map(\.name) ?? [])
        let byName = manifest.targets.flatMap { target in
            target.dependencies.compactMap { use -> String? in
                guard case .byName(let product, _) = use, products.contains(product) else { return nil }
                return "\(target.name) uses \(product)"
            }
        }
        guard byName.isEmpty else {
            throw WorkspaceError(description: "\(byName.joined(separator: "; ")) by name; change those to .product(name:package:) or remove them first")
        }

        let edited = try ManifestEditor.removingDependency(Self.match(dependency), from: String(decoding: previous, as: UTF8.self))
        try FileSystem.writeAtomically(Data(edited.utf8), to: manifestFile)
        return RemoveResult(identity: dependency.identity, previousManifest: previous)
    }

    /// Moves version requirements whose newest release they exclude to that release, keeping
    /// each requirement's form (`from:` stays `from:`). Only the named dependencies, or every
    /// dependency when none is named. The caller resolves afterwards.
    public func upgrade(_ names: [String], effect: EditEffect) async throws -> UpgradeResult {
        let (directory, manifest) = try await self.rootManifest()
        let selected = try names.isEmpty ? manifest.dependencies : names.map { try Self.dependency(named: $0, in: manifest) }
        let manifestFile = directory.appendingPathComponent(WellKnownFile.manifest)
        let previous = try FileSystem.read(manifestFile)
        let source = String(decoding: previous, as: UTF8.self)

        // Every candidate's releases, listed concurrently.
        let releases = try await self.releases(of: selected, in: directory)

        var changes: [UpgradeChange] = []
        var skipped: [UpgradeSkip] = []
        var edited = source
        for dependency in selected.sorted(by: { $0.identity < $1.identity }) {
            let match = Self.match(dependency)
            switch Self.plan(dependency, syntax: ManifestEditor.requirement(of: match, in: source), releases: releases[dependency.identity] ?? []) {
            case .upgrade(let from, let to):
                edited = try ManifestEditor.settingVersion(to, of: match, in: edited)
                changes.append(UpgradeChange(identity: dependency.identity, from: from, to: to))
            case .skip(let reason):
                skipped.append(UpgradeSkip(identity: dependency.identity, reason: reason))
            case .current:
                continue
            }
        }

        guard effect == .apply, !changes.isEmpty else {
            return UpgradeResult(changes: changes, skipped: skipped, previousManifest: nil)
        }
        try FileSystem.writeAtomically(Data(edited.utf8), to: manifestFile)
        return UpgradeResult(changes: changes, skipped: skipped, previousManifest: previous)
    }

    /// Puts back the manifest an edit replaced (when the resolve after it fails).
    public func restoreManifest(_ contents: Data) throws {
        guard case .package(let directory) = self.options.root else { return }
        try FileSystem.writeAtomically(contents, to: directory.appendingPathComponent(WellKnownFile.manifest))
    }

    // MARK: Planning upgrades

    private enum UpgradePlan {
        case upgrade(from: String, to: String)
        case skip(String)
        case current
    }

    /// Whether the newest release falls outside the requirement, and what to write instead.
    private static func plan(_ dependency: Manifest.Dependency, syntax: RequirementSyntax?, releases: [Version]) -> UpgradePlan {
        guard case .range(let lower, let upper) = dependency.requirement, let lowerBound = Version(lower), let upperBound = Version(upper) else {
            // Exact versions are ranges of one version in the model, so only these remain.
            return Self.planExact(dependency, syntax: syntax, releases: releases)
        }
        guard let latest = Self.latest(of: releases, from: lowerBound) else {
            return .skip("no releases found")
        }
        guard latest >= upperBound else { return .current }

        switch syntax {
        case .upToNextMajor(let written), .upToNextMinor(let written), .exact(let written):
            return .upgrade(from: written, to: latest.description)
        case .range:
            return .skip("a range (\(lower)..<\(upper)); \(latest) is out of it, edit it by hand")
        case .unversioned, nil:
            return .skip("its requirement isn't written as a literal")
        }
    }

    private static func planExact(_ dependency: Manifest.Dependency, syntax: RequirementSyntax?, releases: [Version]) -> UpgradePlan {
        guard case .exact(let pinned) = dependency.requirement, let current = Version(pinned) else {
            return .current
        }
        guard let latest = Self.latest(of: releases, from: current) else {
            return .skip("no releases found")
        }
        guard latest > current, case .exact(let written)? = syntax else { return .current }
        return .upgrade(from: written, to: latest.description)
    }

    /// The newest stable release; pre-releases count only when the requirement starts at one.
    private static func latest(of releases: [Version], from current: Version) -> Version? {
        releases.filter { current.hasPrerelease || !$0.hasPrerelease }.max()
    }

    // MARK: Lookups

    private func rootManifest() async throws -> (URL, Manifest) {
        guard case .package(let directory) = self.options.root else {
            throw WorkspaceError(description: "this works on packages; edit Xcode projects' packages in Xcode")
        }
        let toolchain = try await Toolchain.detect(store: self.store)
        let loader = ManifestLoader(store: self.store, toolchain: toolchain, maximumConcurrency: self.options.maximumConcurrency)
        return (directory, try await loader.load(packageAt: directory))
    }

    /// A root dependency by identity, reference name, or URL.
    private static func dependency(named name: String, in manifest: Manifest) throws -> Manifest.Dependency {
        let wanted = name.lowercased()
        let identity = PackageIdentity(location: name).description
        let found = manifest.dependencies.first { dependency in
            dependency.identity == wanted || dependency.identity == identity || dependency.referenceName.lowercased() == wanted
        }
        guard let found else {
            let known = manifest.dependencies.map(\.identity).joined(separator: ", ")
            throw WorkspaceError(description: "\(name) isn't a dependency of the package; it depends on \(known.isEmpty ? "nothing" : known)")
        }
        return found
    }

    private static func match(_ dependency: Manifest.Dependency) -> DependencyMatch {
        DependencyMatch(identity: dependency.identity, referenceNames: Set([dependency.referenceName] + (dependency.explicitName.map { [$0] } ?? [])))
    }

    /// Released versions of each versioned dependency: tags for git packages, the registry's list
    /// for registry packages. Path dependencies have none.
    private func releases(of dependencies: [Manifest.Dependency], in directory: URL) async throws -> [String: [Version]] {
        let root = try await self.rootContext()
        let toolchain = try await Toolchain.detect(store: self.store)
        let source = GitSource(store: self.store, maximumConcurrency: self.options.maximumConcurrency)
        let registry = self.registrySource(for: root)

        return try await withThrowingTaskGroup(of: (String, [Version]).self) { group in
            for dependency in dependencies {
                group.addTask {
                    switch dependency.location {
                    case .remote(let url):
                        return (dependency.identity, try await source.versions(of: .remote(url), toolsVersion: toolchain.toolsVersion).map(\.version))
                    case .localSourceControl(let path):
                        let absolute = URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL.path
                        let reference = PackageReference(identity: PackageIdentity(location: absolute), kind: .localSourceControl(path: absolute))
                        return (dependency.identity, try await source.versions(of: reference, toolsVersion: toolchain.toolsVersion).map(\.version))
                    case .registry(let identity):
                        return (dependency.identity, try await registry.versions(of: PackageIdentity(plain: identity)))
                    case .local:
                        return (dependency.identity, [])
                    }
                }
            }
            return try await group.reduce(into: [String: [Version]]()) { $0[$1.0] = $1.1 }
        }
    }
}
