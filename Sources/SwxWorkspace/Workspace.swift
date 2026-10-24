import Foundation
import SwxCore
import SwxManifest
import SwxResolver
import SwxSource
import SwxStore
import SwxSystem

/// Whether existing pins constrain resolution.
public enum ResolveMode: Sendable {
    /// Keep pinned versions whenever they still satisfy the manifests (`swift package resolve`).
    case respectPins
    /// Ignore pins and pick the newest allowed versions (`swift package update`).
    case update
}

/// How a resolve finished.
public enum ResolveOutcome: Sendable {
    /// Nothing to do: `Package.resolved` and checkouts already match.
    case upToDate
    /// Checkouts restored from `Package.resolved` without running the solver.
    case restoredFromPins
    /// The solver ran.
    case resolved
}

public struct PinChange: Sendable, Hashable {
    public let identity: PackageIdentity
    public let old: PinState?
    public let new: PinState?
}

public struct ResolveReport: Sendable {
    public let outcome: ResolveOutcome
    public let pins: [Pin]
    public let changes: [PinChange]
    public let materialized: Int
}

/// Diagnostic output detail.
public enum Verbosity: Sendable, Comparable {
    case quiet
    case normal
    case verbose
}

public struct WorkspaceOptions: Sendable {
    public var packagePath: URL
    /// Overrides the shared cache location (otherwise `SWX_CACHE_DIR`, `XDG_CACHE_HOME`, `~/.cache/swx`).
    public var cacheDirectory: URL?
    public var maximumConcurrency: Int
    public var verbosity: Verbosity

    public init(packagePath: URL, cacheDirectory: URL?, maximumConcurrency: Int, verbosity: Verbosity) {
        self.packagePath = packagePath
        self.cacheDirectory = cacheDirectory
        self.maximumConcurrency = maximumConcurrency
        self.verbosity = verbosity
    }
}

/// Orchestrates resolution for one root package. The imperative shell around the pure solver.
public struct Workspace: Sendable {
    private let options: WorkspaceOptions
    private let store: Store

    public init(options: WorkspaceOptions) {
        self.options = options
        self.store = options.cacheDirectory.map(Store.init(root:)) ?? Store.default()
    }

    // MARK: Locations

    private var buildDirectory: URL {
        self.options.packagePath.appendingPathComponent(WellKnownFile.buildDirectory, isDirectory: true)
    }

    private var checkoutsDirectory: URL {
        self.buildDirectory.appendingPathComponent(WellKnownFile.checkoutsDirectory, isDirectory: true)
    }

    private var resolvedFilePath: URL {
        self.options.packagePath.appendingPathComponent(WellKnownFile.packageResolved)
    }

    private var workspaceStatePath: URL {
        self.buildDirectory.appendingPathComponent(WellKnownFile.workspaceState)
    }

    // MARK: Resolve

    public func resolve(mode: ResolveMode) async throws -> ResolveReport {
        // Hash the root manifest exactly as SwiftPM computes `originHash`.
        let rootManifest = try self.rootManifestContents()
        let originHash = ContentHash.sha256(rootManifest.data)

        // Load what's on disk.
        let resolvedFile = try FileSystem.readIfPresent(self.resolvedFilePath).map(ResolvedFile.decode)
        let state = FileSystem.readIfPresent(self.workspaceStatePath).flatMap(WorkspaceState.decodeIfCompatible)
            ?? WorkspaceState(dependencies: [:])

        // Fast paths: the lockfile is authoritative when it was produced from this exact manifest.
        if mode == .respectPins, let resolvedFile, resolvedFile.originHash == originHash {
            let pins = Array(resolvedFile.pins.values)
            if self.checkoutsMatch(pins: pins, state: state) {
                return ResolveReport(outcome: .upToDate, pins: pins, changes: [], materialized: 0)
            }
            let source = GitSource(store: self.store, maximumConcurrency: self.options.maximumConcurrency)
            let materialized = try await self.materialize(pins: pins, fileSystemDependencies: [], previous: state, source: source)
            return ResolveReport(outcome: .restoredFromPins, pins: pins, changes: [], materialized: materialized)
        }

        // Full resolution.
        return try await self.fullResolve(
            mode: mode,
            originHash: originHash,
            previousPins: resolvedFile?.pins ?? [:],
            previousState: state
        )
    }

    private func fullResolve(
        mode: ResolveMode,
        originHash: String,
        previousPins: [PackageIdentity: Pin],
        previousState: WorkspaceState
    ) async throws -> ResolveReport {
        let toolchain = try await Toolchain.detect()
        let concurrency = self.options.maximumConcurrency
        let source = GitSource(store: self.store, maximumConcurrency: concurrency)
        let loader = ManifestLoader(store: self.store, toolchain: toolchain, maximumConcurrency: concurrency)
        // Prefer pinned versions unless updating.
        var preferred: [PackageIdentity: Version] = [:]
        if mode == .respectPins {
            for pin in previousPins.values {
                guard case .version(let version, _) = pin.state else { continue }
                preferred[pin.package.identity] = version
            }
        }
        let facts = FactProvider(source: source, loader: loader, toolchain: toolchain, preferred: preferred)

        // Evaluate the root and split its dependencies into versioned ones and overrides.
        let root = try await loader.load(packageAt: self.options.packagePath)
        let rootReference = PackageReference(
            identity: PackageIdentity(location: self.options.packagePath.path),
            kind: .root(path: self.options.packagePath.path)
        )
        let overrides = try await self.collectOverrides(
            root: root,
            mode: mode,
            previousPins: previousPins,
            source: source,
            loader: loader,
            facts: facts
        )
        self.log(.verbose, "root '\(root.name)': \(overrides.rootDependencies.count) dependencies, \(overrides.overridden.count) overrides")
        await facts.speculate(on: overrides.rootDependencies)

        // Drive the pure solver, fulfilling its requests concurrently.
        var solver = Solver(
            root: rootReference,
            rootDependencies: overrides.rootDependencies,
            preferred: preferred,
            overridden: Set(overrides.overridden.keys)
        )
        let bindings = try await self.drive(&solver, facts: facts)

        // Turn bindings and overrides into pins.
        var pins: [Pin] = []
        for binding in bindings {
            guard let revision = await facts.revision(of: binding.package.identity, at: binding.version) else {
                throw WorkspaceError(description: "no revision known for \(binding.package.identity) \(binding.version)")
            }
            pins.append(Pin(package: binding.package, state: .version(binding.version, revision: revision)))
        }
        pins += overrides.overridden.values.compactMap(\.pin)

        // Check out, then record.
        let fileSystemDependencies = overrides.overridden.values.compactMap(\.fileSystemDependency)
        let materialized = try await self.materialize(
            pins: pins,
            fileSystemDependencies: fileSystemDependencies,
            previous: previousState,
            source: source
        )
        let resolved = ResolvedFile(pins: Dictionary(pins.map { ($0.package.identity, $0) }, uniquingKeysWith: { $1 }), originHash: originHash)
        try self.writeResolvedFile(resolved, format: .forTools(root.parsedToolsVersion))

        return ResolveReport(
            outcome: .resolved,
            pins: pins,
            changes: Self.changes(from: previousPins, to: resolved.pins),
            materialized: materialized
        )
    }

    // MARK: Solver loop

    private func drive(_ solver: inout Solver, facts: FactProvider) async throws -> [ResolvedBinding] {
        while true {
            switch solver.resume() {
            case .solved(let bindings):
                return bindings

            case .failed(let failure):
                throw WorkspaceError(description: "Dependency resolution failed:\n\(failure.description)")

            case .needs(let required, let prefetch):
                // Kick off speculative work first so it overlaps with the required fetches.
                for request in prefetch {
                    await facts.start(request)
                }

                // Fetch every required fact in parallel, then feed them back.
                let answers = try await withThrowingTaskGroup(of: Answer.self) { group in
                    for request in required {
                        group.addTask { try await Self.answer(request, facts: facts) }
                    }
                    return try await group.reduce(into: [Answer]()) { $0.append($1) }
                }
                for answer in answers {
                    switch answer {
                    case .versions(let package, let versions):
                        solver.provideVersions(versions, for: package)
                    case .dependencies(let package, let version, let result):
                        solver.provideDependencies(result, for: package, at: version)
                    }
                }
            }
        }
    }

    private enum Answer: Sendable {
        case versions(PackageIdentity, [Version])
        case dependencies(PackageIdentity, Version, DependencyFacts)
    }

    private static func answer(_ request: SolverRequest, facts: FactProvider) async throws -> Answer {
        switch request {
        case .versions(let package):
            let tagged = try await facts.versions(of: package)
            return .versions(package.identity, tagged.map(\.version))
        case .dependencies(let package, let version):
            return .dependencies(package.identity, version, try await facts.dependencies(of: package, at: version))
        }
    }

    // MARK: Overrides (branch, revision and path dependencies of the root)

    private struct Override: Sendable {
        let package: PackageReference
        let state: OverrideState

        var pin: Pin? {
            switch self.state {
            case .branch(let name, let revision):
                return Pin(package: self.package, state: .branch(name, revision: revision))
            case .revision(let revision):
                return Pin(package: self.package, state: .revision(revision))
            case .fileSystem:
                return nil
            }
        }

        var fileSystemDependency: ManagedDependency? {
            guard case .fileSystem(let path) = self.state else { return nil }

            // SwiftPM records path dependencies under their identity, not their name.
            return ManagedDependency(package: self.package, state: .fileSystem(path: path), subpath: self.package.identity.description)
        }
    }

    private enum OverrideState: Sendable {
        case branch(String, revision: String)
        case revision(String)
        case fileSystem(path: String)
    }

    private struct Overrides {
        var rootDependencies: [DependencyDeclaration] = []
        var overridden: [PackageIdentity: Override] = [:]
    }

    /// Fixes unversioned root dependencies outside the solver and lifts their dependencies to the root.
    private func collectOverrides(
        root: Manifest,
        mode: ResolveMode,
        previousPins: [PackageIdentity: Pin],
        source: GitSource,
        loader: ManifestLoader,
        facts: FactProvider
    ) async throws -> Overrides {
        var result = Overrides()
        var pending = root.requiredDependencies(role: .root)

        while !pending.isEmpty {
            let dependency = pending.removeFirst()
            guard let declaration = dependency.declaration else {
                throw WorkspaceError(description: "registry dependency '\(dependency.identity)' is not supported yet")
            }
            let identity = declaration.package.identity
            await facts.noteTraits(dependency.traits, for: identity)

            // Versioned dependencies go to the solver as-is.
            guard declaration.requirement.isUnversioned else {
                result.rootDependencies.append(declaration)
                continue
            }
            guard result.overridden[identity] == nil else { continue }

            // Pin the override and load its manifest to lift its own dependencies.
            let override: Override
            let manifest: Manifest
            switch (declaration.requirement, declaration.package.kind) {
            case (.branch(let branch), _):
                let revision = try await self.branchRevision(branch, of: declaration.package, mode: mode, previousPins: previousPins, source: source)
                override = Override(package: declaration.package, state: .branch(branch, revision: revision))
                manifest = try await self.manifest(of: declaration.package, at: revision, source: source, loader: loader)
            case (.revision(let revision), _):
                override = Override(package: declaration.package, state: .revision(revision))
                manifest = try await self.manifest(of: declaration.package, at: revision, source: source, loader: loader)
            case (_, .fileSystem(let path)):
                override = Override(package: declaration.package, state: .fileSystem(path: path))
                manifest = try await loader.load(packageAt: URL(fileURLWithPath: path))
            default:
                throw WorkspaceError(description: "unsupported requirement for \(identity): \(declaration.requirement)")
            }
            result.overridden[identity] = override
            pending += manifest.requiredDependencies(role: .dependency)
        }
        return result
    }

    /// A branch keeps its pinned commit unless updating (SwiftPM behaviour).
    private func branchRevision(
        _ branch: String,
        of package: PackageReference,
        mode: ResolveMode,
        previousPins: [PackageIdentity: Pin],
        source: GitSource
    ) async throws -> String {
        if mode == .respectPins, case .branch(let pinnedBranch, let revision)? = previousPins[package.identity]?.state, pinnedBranch == branch {
            return revision
        }
        return try await source.resolveBranch(branch, of: package)
    }

    private func manifest(of package: PackageReference, at revision: String, source: GitSource, loader: ManifestLoader) async throws -> Manifest {
        guard let files = try await source.manifestFiles(of: package, at: [revision])[revision],
              let contents = files.files[WellKnownFile.manifest] else {
            throw WorkspaceError(description: "no Package.swift in \(package.identity) at \(revision)")
        }
        return try await loader.load(contents: contents)
    }

    // MARK: Checkouts

    /// Are all pins already checked out at the right revisions?
    private func checkoutsMatch(pins: [Pin], state: WorkspaceState) -> Bool {
        pins.allSatisfy { pin in
            guard let managed = state.dependencies[pin.package.identity],
                  case .sourceControlCheckout(let checkedOut) = managed.state,
                  checkedOut == pin.state else {
                return false
            }
            return FileSystem.isDirectory(self.checkoutsDirectory.appendingPathComponent(managed.subpath))
        }
    }

    /// Places every pinned tree into `.build/checkouts` and writes workspace state.
    private func materialize(
        pins: [Pin],
        fileSystemDependencies: [ManagedDependency],
        previous: WorkspaceState,
        source: GitSource
    ) async throws -> Int {
        // Only touch checkouts whose revision changed or whose directory is missing.
        let stale = pins.filter { !self.checkoutsMatch(pins: [$0], state: previous) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for pin in stale {
                group.addTask {
                    let tree = try await source.sourceTree(of: pin.package, revision: pin.state.revision)
                    let destination = self.checkoutsDirectory.appendingPathComponent(pin.package.name)
                    let strategy = try Materializer.materialize(tree, at: destination)
                    self.log(.verbose, "checked out \(pin.package.identity) \(pin.state) (\(strategy))")
                }
            }
            try await group.waitForAll()
        }

        // Remove checkouts of packages that are no longer dependencies.
        let current = Set(pins.map(\.package.identity))
        for (identity, managed) in previous.dependencies where !current.contains(identity) {
            guard case .sourceControlCheckout = managed.state else { continue }
            try FileSystem.removeTree(self.checkoutsDirectory.appendingPathComponent(managed.subpath))
        }

        // Record the new state, keeping SwiftPM's own artifacts and prebuilts.
        var state = previous
        state.dependencies = [:]
        for pin in pins {
            state.dependencies[pin.package.identity] = ManagedDependency(
                package: pin.package,
                state: .sourceControlCheckout(pin.state),
                subpath: pin.package.name
            )
        }
        for dependency in fileSystemDependencies {
            state.dependencies[dependency.package.identity] = dependency
        }
        try FileSystem.writeAtomically(try state.encode(), to: self.workspaceStatePath)
        return stale.count
    }

    // MARK: Files

    private struct RootManifest {
        let data: Data
    }

    /// The root manifest SwiftPM hashes for `originHash` (version-specific manifests aside).
    private func rootManifestContents() throws -> RootManifest {
        let url = self.options.packagePath.appendingPathComponent(WellKnownFile.manifest)
        guard let data = FileSystem.readIfPresent(url) else {
            throw WorkspaceError(description: "no \(WellKnownFile.manifest) found in \(self.options.packagePath.path)")
        }
        return RootManifest(data: data)
    }

    /// Writes only when the bytes change, and removes the file when there are no pins (like SwiftPM).
    private func writeResolvedFile(_ file: ResolvedFile, format: ResolvedFile.FormatVersion) throws {
        guard !file.pins.isEmpty else {
            try FileSystem.removeTree(self.resolvedFilePath)
            return
        }
        let data = try file.encode(format: format)
        guard FileSystem.readIfPresent(self.resolvedFilePath) != data else { return }
        try FileSystem.writeAtomically(data, to: self.resolvedFilePath)
    }

    private static func changes(from old: [PackageIdentity: Pin], to new: [PackageIdentity: Pin]) -> [PinChange] {
        let identities = Set(old.keys).union(new.keys).sorted()
        return identities.compactMap { identity in
            let before = old[identity]?.state
            let after = new[identity]?.state
            return before == after ? nil : PinChange(identity: identity, old: before, new: after)
        }
    }

    private func log(_ level: Verbosity, _ message: @autoclosure () -> String) {
        guard self.options.verbosity >= level else { return }
        FileHandle.standardError.write(Data("[swx] \(message())\n".utf8))
    }
}
