import SwxCore
import SwxManifest
import SwxResolver
import SwxSource
import SwxSystem

/// Where the solver learns which versions of a package exist.
enum VersionCatalog: Sendable {
    /// Tags listed from each repository.
    case remote
    /// Only the pinned versions: SwiftPM's resolution precomputation, which needs no network
    /// when the pins still satisfy every requirement.
    case pinned([PackageIdentity: TaggedVersion])
}

/// The pins alone can't satisfy the requirements (a new package, or a changed requirement).
struct PinsNoLongerFit: Error {
    let reason: String
}

/// Answers solver requests, memoizing each one as a task so that prefetches started
/// early are simply awaited when the solver later requires them.
actor FactProvider {
    private let source: GitSource
    private let registry: RegistrySource
    private let loader: ManifestLoader
    private let toolchain: Toolchain

    private var versionTasks: [PackageIdentity: Task<[TaggedVersion], Error>] = [:]
    private var dependencyTasks: [PackageVersionKey: Task<DependencyFacts, Error>] = [:]
    private var revisions: [PackageIdentity: [Version: String]] = [:]

    /// Traits requested for each package by its dependents (default: `default`).
    private var requestedTraits: [PackageIdentity: Set<String>] = [:]

    /// Versions the solver will probably choose (pins), used to aim speculative prefetches.
    private let preferred: [PackageIdentity: Version]

    /// Upper bound on speculative manifest loads, so a pathological graph can't run away.
    private static let speculationLimit = 256
    private var speculations = 0
    /// Packages whose likely manifest was already read over HTTP for hints.
    private var hinted: Set<PackageIdentity> = []

    private struct PackageVersionKey: Hashable {
        let package: PackageIdentity
        let version: Version
    }

    private let mirrors: DependencyMirrors
    private let catalog: VersionCatalog
    private let transformer: RegistryTransformer

    init(
        source: GitSource,
        registry: RegistrySource,
        loader: ManifestLoader,
        toolchain: Toolchain,
        preferred: [PackageIdentity: Version],
        mirrors: DependencyMirrors,
        catalog: VersionCatalog,
        transformation: RegistryTransformation
    ) {
        self.source = source
        self.registry = registry
        self.loader = loader
        self.toolchain = toolchain
        self.preferred = preferred
        self.mirrors = mirrors
        self.catalog = catalog
        self.transformer = RegistryTransformer(mode: transformation, registry: registry)
    }

    /// Every manifest resolution reads goes through SwiftPM's source-control-to-registry rules.
    func transform(_ manifest: Manifest) async -> Manifest {
        await self.transformer.transform(manifest)
    }

    /// The tools version manifests are selected and checked against.
    nonisolated var toolsVersion: ToolsVersion {
        self.toolchain.toolsVersion
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

        // Registry releases have no commit to remember.
        if case .registry = package.kind {
            return tagged
        }
        self.revisions[package.identity] = Dictionary(tagged.map { ($0.version, $0.revision) }, uniquingKeysWith: { first, _ in first })
        return tagged
    }

    func dependencies(of package: PackageReference, at version: Version) async throws -> DependencyFacts {
        try await self.dependenciesTask(for: package, at: version).value
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
            guard case .version(let requirement) = declaration.requirement, Self.isVersioned(declaration.package.kind) else { continue }
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

        let candidate: TaggedVersion?
        if let pinned = self.preferred[package.identity], requirement.contains(pinned), let tag = tagged.first(where: { $0.version == pinned }) {
            candidate = tag
        } else {
            candidate = tagged.last { requirement.contains($0.version) }
        }
        guard let candidate else { return }

        self.speculations += 1
        _ = self.dependenciesTask(for: package, at: candidate.version)
        self.hint(package, revision: candidate.revision)
    }

    /// Reads the candidate's manifest over HTTP (GitHub) and starts on its dependencies: their
    /// tag lists and clones then overlap with this package's clone instead of following it.
    /// Nothing the solver sees comes from here.
    private func hint(_ package: PackageReference, revision: String) {
        guard ManifestHints.isEnabled, case .remoteSourceControl(let url) = package.kind, self.hinted.insert(package.identity).inserted else { return }
        let environment = CompilationEnvironment.host(compilerVersion: self.toolchain.toolsVersion)
        Task { [loader] in
            guard let contents = await ManifestHints.manifest(url: url, revision: revision) else { return }

            // Declarative manifests parse at once. Others start compiling now: evaluations are
            // cached by content, and git serves these same bytes when resolution reads them.
            var parsed = StaticManifestParser.parse(contents, environment: environment)
            if parsed == nil {
                parsed = try? await loader.load(contents: contents)
            }
            guard let manifest = parsed else { return }
            Trace.event("hint \(package.identity): \(manifest.dependencies.count) dependencies")
            let declarations = manifest.requiredDependencies(role: .dependency).map { self.mirrors.effective($0.declaration) }
            self.speculate(on: declarations)
        }
    }

    /// Packages whose versions come from tags or a registry (not path dependencies).
    private static func isVersioned(_ kind: PackageKind) -> Bool {
        switch kind {
        case .remoteSourceControl, .localSourceControl, .registry:
            return true
        case .root, .fileSystem:
            return false
        }
    }

    /// Registry versions carry no commit; the solver only reads the version.
    private static let registryRevision = ""

    // MARK: Tasks

    private func versionsTask(for package: PackageReference) -> Task<[TaggedVersion], Error> {
        if let existing = self.versionTasks[package.identity] {
            return existing
        }
        let task: Task<[TaggedVersion], Error>
        switch self.catalog {
        case .remote:
            task = Task { [source, registry, toolchain] in
                guard case .registry = package.kind else {
                    return try await source.versions(of: package, toolsVersion: toolchain.toolsVersion)
                }
                return try await registry.versions(of: package.identity).map { TaggedVersion(version: $0, revision: Self.registryRevision) }
            }
        case .pinned(let pins):
            // An unpinned package means the graph changed: only a real resolve can place it.
            let pinned = pins[package.identity]
            task = Task {
                guard let pinned else { throw PinsNoLongerFit(reason: "\(package.identity) is not pinned") }
                return [pinned]
            }
        }
        self.versionTasks[package.identity] = task
        return task
    }

    private func dependenciesTask(for package: PackageReference, at version: Version) -> Task<DependencyFacts, Error> {
        let key = PackageVersionKey(package: package.identity, version: version)
        if let existing = self.dependencyTasks[key] {
            return existing
        }
        let task = Task { try await self.loadDependencies(of: package, at: version) }
        self.dependencyTasks[key] = task
        return task
    }

    /// Reads and evaluates the manifest at a tagged version, then prunes its dependencies.
    ///
    /// Like SwiftPM, only an incompatible tools version rules a version out; any other failure
    /// (network, git, a broken manifest) aborts resolution rather than silently picking another version.
    private func loadDependencies(of package: PackageReference, at version: Version) async throws -> DependencyFacts {
        do {
            // Pick the manifest SwiftPM would pick, and reject newer tools versions without evaluating.
            let contents = try await self.manifestContents(of: package, at: version)
            let declaredToolsVersion = try ToolsVersion.specification(of: contents)

            // Like SwiftPM, a manifest older than 4.0 (or without a specification) fails the resolve.
            guard declaredToolsVersion >= ToolsVersion.minimumSupported else {
                throw WorkspaceError(description: "package '\(package.identity)' is using Swift tools version \(declaredToolsVersion) which is no longer supported; consider using '// swift-tools-version: \(self.toolchain.toolsVersion)' to specify the current tools version")
            }
            guard declaredToolsVersion <= self.toolchain.toolsVersion else {
                return .unavailable(reason: "requires tools version \(declaredToolsVersion), current is \(self.toolchain.toolsVersion)")
            }

            // Evaluate (cached by content) and keep only the dependencies resolution needs.
            let manifest = await self.transform(try await self.loader.load(contents: contents))
            let traits = self.requestedTraits[package.identity] ?? [Manifest.defaultTrait]
            let required = manifest.requiredDependencies(role: .dependency, enabledTraits: traits)

            var declarations: [DependencyDeclaration] = []
            for dependency in required {
                let declaration = self.mirrors.effective(dependency.declaration)
                self.noteTraits(dependency.requestedTraits(enabledInParent: manifest.expand(traits: traits)), for: declaration.package.identity)
                declarations.append(declaration)
            }

            // Walk ahead of the solver: the whole graph streams in instead of level by level.
            self.speculate(on: declarations)
            return .available(declarations)
        } catch let error as WorkspaceError {
            throw error
        } catch let miss as PinsNoLongerFit {
            throw miss
        } catch {
            throw WorkspaceError(description: "\(package.identity) \(version): \(error)")
        }
    }

    /// The selected manifest's text, from the registry or from git at the version's commit.
    /// Either way the version considered is usually the one chosen, so its download starts now.
    private func manifestContents(of package: PackageReference, at version: Version) async throws -> String {
        if case .registry = package.kind {
            let registry = self.registry
            Task { _ = try? await registry.sourceTree(of: package.identity, version: version) }
            return try await registry.manifest(of: package.identity, version: version, toolsVersion: self.toolchain.toolsVersion)
        }

        // Map the version to its commit.
        _ = try await self.versions(of: package)
        guard let revision = self.revisions[package.identity]?[version] else {
            throw WorkspaceError(description: "no tag for \(package.identity) \(version)")
        }
        await self.source.prefetchSourceTree(of: package, revision: revision)

        let files = try await self.source.manifestFiles(of: package, at: [revision])[revision]
        guard let files, let manifestName = ToolsVersion.selectManifest(
            fileNames: files.rootFileNames,
            current: self.toolchain.toolsVersion,
            contentsOf: { files.files[$0] }
        ), let contents = files.files[manifestName] else {
            throw WorkspaceError(description: "\(package.identity) has no Package.swift at \(version)")
        }
        return contents
    }
}
