import SwxCore
import SwxManifest
import SwxResolver
import SwxSource

/// Answers solver requests, memoizing each one as a task so that prefetches started
/// early are simply awaited when the solver later requires them.
actor FactProvider {
    private let source: GitSource
    private let loader: ManifestLoader
    private let toolchain: Toolchain

    private var versionTasks: [PackageIdentity: Task<[TaggedVersion], Error>] = [:]
    private var dependencyTasks: [PackageVersionKey: Task<DependencyFacts, Never>] = [:]
    private var revisions: [PackageIdentity: [Version: String]] = [:]

    /// Traits requested for each package by its dependents (default: `default`).
    private var requestedTraits: [PackageIdentity: Set<String>] = [:]

    /// Versions the solver will probably choose (pins), used to aim speculative prefetches.
    private let preferred: [PackageIdentity: Version]

    /// Upper bound on speculative manifest loads, so a pathological graph can't run away.
    private static let speculationLimit = 256
    private var speculations = 0

    private struct PackageVersionKey: Hashable {
        let package: PackageIdentity
        let version: Version
    }

    init(source: GitSource, loader: ManifestLoader, toolchain: Toolchain, preferred: [PackageIdentity: Version]) {
        self.source = source
        self.loader = loader
        self.toolchain = toolchain
        self.preferred = preferred
    }

    // MARK: Requests

    /// Starts work for a request without waiting for it.
    func start(_ request: SolverRequest) {
        switch request {
        case .versions(let package):
            _ = self.versionsTask(for: package)
        case .dependencies(let package, let version):
            _ = self.dependenciesTask(for: package, at: version)
        }
    }

    func versions(of package: PackageReference) async throws -> [TaggedVersion] {
        let tagged = try await self.versionsTask(for: package).value
        self.revisions[package.identity] = Dictionary(tagged.map { ($0.version, $0.revision) }, uniquingKeysWith: { first, _ in first })
        return tagged
    }

    func dependencies(of package: PackageReference, at version: Version) async -> DependencyFacts {
        await self.dependenciesTask(for: package, at: version).value
    }

    /// The commit behind `version`, once the version list is known.
    func revision(of package: PackageIdentity, at version: Version) -> String? {
        self.revisions[package]?[version]
    }

    func noteTraits(_ traits: [String], for package: PackageIdentity) {
        self.requestedTraits[package, default: []].formUnion(traits)
    }

    // MARK: Speculation

    /// Starts tag listing for each dependency, then loads the manifest of its likely version.
    func speculate(on declarations: [DependencyDeclaration]) {
        for declaration in declarations {
            guard case .version(let requirement) = declaration.requirement,
                  case .remoteSourceControl = declaration.package.kind else { continue }
            let versions = self.versionsTask(for: declaration.package)

            Task {
                guard let tagged = try? await versions.value else { return }
                self.speculateManifest(of: declaration.package, requirement: requirement, tagged: tagged)
            }
        }
    }

    /// The pin if it still fits, else the newest matching version: what the solver tries first.
    private func speculateManifest(of package: PackageReference, requirement: VersionRequirement, tagged: [TaggedVersion]) {
        guard self.speculations < Self.speculationLimit else { return }

        let candidate: Version?
        if let pinned = self.preferred[package.identity], requirement.contains(pinned), tagged.contains(where: { $0.version == pinned }) {
            candidate = pinned
        } else {
            candidate = tagged.last { requirement.contains($0.version) }?.version
        }
        guard let candidate else { return }

        self.speculations += 1
        _ = self.dependenciesTask(for: package, at: candidate)
    }

    // MARK: Tasks

    private func versionsTask(for package: PackageReference) -> Task<[TaggedVersion], Error> {
        if let existing = self.versionTasks[package.identity] {
            return existing
        }
        let task = Task { [source, toolchain] in try await source.versions(of: package, toolsVersion: toolchain.toolsVersion) }
        self.versionTasks[package.identity] = task
        return task
    }

    private func dependenciesTask(for package: PackageReference, at version: Version) -> Task<DependencyFacts, Never> {
        let key = PackageVersionKey(package: package.identity, version: version)
        if let existing = self.dependencyTasks[key] {
            return existing
        }
        let task = Task { await self.loadDependencies(of: package, at: version) }
        self.dependencyTasks[key] = task
        return task
    }

    /// Reads and evaluates the manifest at a tagged version, then prunes its dependencies.
    private func loadDependencies(of package: PackageReference, at version: Version) async -> DependencyFacts {
        do {
            // Map the version to its commit.
            _ = try await self.versions(of: package)
            guard let revision = self.revisions[package.identity]?[version] else {
                return .unavailable(reason: "no tag for version \(version)")
            }

            // The version being considered is usually the one chosen: start its checkout now.
            await self.source.prefetchSourceTree(of: package, revision: revision)

            // Pick the manifest SwiftPM would pick, and reject newer tools versions without evaluating.
            let files = try await self.source.manifestFiles(of: package, at: [revision])[revision]
            guard let files, let manifestName = ToolsVersion.selectManifest(
                fileNames: files.rootFileNames,
                current: self.toolchain.toolsVersion,
                contentsOf: { files.files[$0] }
            ), let contents = files.files[manifestName] else {
                return .unavailable(reason: "no Package.swift at \(version)")
            }
            let declaredToolsVersion = ToolsVersion.parse(manifest: contents)
            guard declaredToolsVersion <= self.toolchain.toolsVersion else {
                return .unavailable(reason: "requires tools version \(declaredToolsVersion), current is \(self.toolchain.toolsVersion)")
            }

            // Evaluate (cached by content) and keep only the dependencies resolution needs.
            let manifest = try await self.loader.load(contents: contents)
            let traits = self.requestedTraits[package.identity] ?? [Manifest.defaultTrait]
            let required = manifest.requiredDependencies(role: .dependency, enabledTraits: traits)

            var declarations: [DependencyDeclaration] = []
            for dependency in required {
                guard let declaration = dependency.declaration else {
                    return .unavailable(reason: "registry dependency '\(dependency.identity)' is not supported yet")
                }
                self.noteTraits(dependency.traits, for: declaration.package.identity)
                declarations.append(declaration)
            }

            // Walk ahead of the solver: the whole graph streams in instead of level by level.
            self.speculate(on: declarations)
            return .available(declarations)
        } catch {
            return .unavailable(reason: String(describing: error))
        }
    }
}
