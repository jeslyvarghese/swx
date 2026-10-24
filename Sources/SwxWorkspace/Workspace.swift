import Foundation
import SwxCore
import SwxManifest
import SwxResolver
import SwxSource
import SwxStore
import SwxSystem
import SwxXcode

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

/// What is being resolved.
public enum WorkspaceRoot: Sendable {
    /// A Swift package directory: pins in `Package.resolved`, checkouts in `.build`.
    case package(URL)
    /// An `.xcodeproj` or `.xcworkspace`: pins in its shared data, checkouts in `sourcePackages`
    /// (hand that directory to `xcodebuild -clonedSourcePackagesDirPath`).
    case xcodeProject(URL, sourcePackages: URL)
    /// A package built by xcodebuild: pins in its `Package.resolved`, checkouts in `sourcePackages`.
    case packageForXcode(URL, sourcePackages: URL)
}

public struct WorkspaceOptions: Sendable {
    public var root: WorkspaceRoot
    /// Overrides the shared cache location (otherwise `SWX_CACHE_DIR`, `XDG_CACHE_HOME`, `~/.cache/swx`).
    public var cacheDirectory: URL?
    public var maximumConcurrency: Int
    public var verbosity: Verbosity

    public init(root: WorkspaceRoot, cacheDirectory: URL?, maximumConcurrency: Int, verbosity: Verbosity) {
        self.root = root
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

    /// Where pins, state and checkouts live for this root.
    struct Layout: Sendable {
        let resolvedFile: URL
        /// `.build` for packages, `SourcePackages` for Xcode.
        let stateDirectory: URL

        var checkoutsDirectory: URL {
            self.stateDirectory.appendingPathComponent(WellKnownFile.checkoutsDirectory, isDirectory: true)
        }

        var workspaceState: URL {
            self.stateDirectory.appendingPathComponent(WellKnownFile.workspaceState)
        }
    }

    /// The root's identity, origin hash, and how to obtain its manifest.
    private struct RootContext: Sendable {
        let reference: PackageReference
        let originHash: String
        let layout: Layout
        let source: RootSource
        let mirrors: DependencyMirrors
    }

    private enum RootSource: Sendable {
        case package(URL)
        /// Xcode declares dependencies directly; there is no manifest to evaluate.
        case xcode(Manifest)
    }

    /// Xcode always writes `Package.resolved` v3.
    private static let xcodeToolsVersion = "6.0.0"

    private func rootContext() async throws -> RootContext {
        switch self.options.root {
        case .package(let directory):
            return try Self.packageContext(directory, stateDirectory: directory.appendingPathComponent(WellKnownFile.buildDirectory, isDirectory: true))

        case .packageForXcode(let directory, let sourcePackages):
            // Same pins and origin hash as SwiftPM; only the checkout location differs.
            return try Self.packageContext(directory, stateDirectory: sourcePackages)

        case .xcodeProject(let url, let sourcePackages):
            // Xcode passes its package references as root dependencies, so SwiftPM hashes their locations.
            let project = try await XcodeProjectReader.read(url)
            let originHash = ContentHash.sha256(project.packageReferences.map(\.locationString).joined())
            let manifest = Manifest(
                name: project.name,
                toolsVersion: Self.xcodeToolsVersion,
                dependencies: project.packageReferences.map(Self.dependency),
                targets: [],
                products: [],
                traits: []
            )
            return RootContext(
                reference: PackageReference(identity: PackageIdentity(location: url.path), kind: .root(path: url.path)),
                originHash: originHash,
                layout: Layout(resolvedFile: project.resolvedFile, stateDirectory: sourcePackages),
                source: .xcode(manifest),
                mirrors: DependencyMirrors.load(for: url.deletingLastPathComponent())
            )
        }
    }

    /// SwiftPM: originHash is the SHA-256 of the root manifest's bytes.
    private static func packageContext(_ directory: URL, stateDirectory: URL) throws -> RootContext {
        let manifestURL = directory.appendingPathComponent(WellKnownFile.manifest)
        guard let data = FileSystem.readIfPresent(manifestURL) else {
            throw WorkspaceError(description: "no \(WellKnownFile.manifest) found in \(directory.path)")
        }
        let layout = Layout(resolvedFile: directory.appendingPathComponent(WellKnownFile.packageResolved), stateDirectory: stateDirectory)
        return RootContext(
            reference: PackageReference(identity: PackageIdentity(location: directory.path), kind: .root(path: directory.path)),
            originHash: ContentHash.sha256(data),
            layout: layout,
            source: .package(directory),
            mirrors: DependencyMirrors.load(for: directory)
        )
    }

    /// An Xcode package reference as a manifest dependency.
    private static func dependency(_ reference: XcodePackageReference) -> Manifest.Dependency {
        let requirement: Manifest.Dependency.Requirement
        switch reference.requirement {
        case .version(.range(let range)):
            requirement = .range(lowerBound: range.lowerBound.description, upperBound: range.upperBound.description)
        case .version(.exact(let version)):
            requirement = .exact(version.description)
        case .branch(let branch):
            requirement = .branch(branch)
        case .revision(let revision):
            requirement = .revision(revision)
        case .unversioned:
            requirement = .none
        }

        switch reference.location {
        case .remote(let url):
            return Manifest.Dependency(identity: PackageIdentity(location: url).description, explicitName: nil, location: .remote(url: url), requirement: requirement, traits: [Manifest.defaultTrait])
        case .local(let path):
            return Manifest.Dependency(identity: PackageIdentity(location: path).description, explicitName: nil, location: .local(path: path), requirement: requirement, traits: [Manifest.defaultTrait])
        }
    }

    /// The project or workspace xcodebuild would pick in `directory`.
    public static func locateXcodeProject(in directory: URL) throws -> URL {
        try XcodeProjectReader.locate(in: directory)
    }

    // MARK: Resolve

    public func resolve(mode: ResolveMode) async throws -> ResolveReport {
        let root = try await self.rootContext()
        let layout = root.layout
        let originHash = root.originHash

        // Load what's on disk.
        let resolvedFile = try FileSystem.readIfPresent(layout.resolvedFile).map(ResolvedFile.decode)
        let state = FileSystem.readIfPresent(layout.workspaceState).flatMap(WorkspaceState.decodeIfCompatible)
            ?? WorkspaceState(dependencies: [:])

        // Fast paths: the lockfile is authoritative when it was produced from this exact manifest.
        if mode == .respectPins, let resolvedFile, resolvedFile.originHash == originHash {
            // Pins name original locations; checkouts come from the mirrors.
            let pins = resolvedFile.pins.values.map { Pin(package: root.mirrors.effective($0.package), state: $0.state) }
            if Self.checkoutsMatch(pins: pins, state: state, layout: layout) {
                return ResolveReport(outcome: .upToDate, pins: pins, changes: [], materialized: 0)
            }
            let source = GitSource(store: self.store, maximumConcurrency: self.options.maximumConcurrency)
            let materialized = try await self.materialize(pins: pins, fileSystemDependencies: [], previous: state, source: source, layout: layout)
            return ResolveReport(outcome: .restoredFromPins, pins: pins, changes: [], materialized: materialized)
        }

        // Full resolution.
        return try await self.fullResolve(
            mode: mode,
            root: root,
            previousPins: resolvedFile?.pins ?? [:],
            previousState: state
        )
    }

    private func fullResolve(
        mode: ResolveMode,
        root rootContext: RootContext,
        previousPins: [PackageIdentity: Pin],
        previousState: WorkspaceState
    ) async throws -> ResolveReport {
        let layout = rootContext.layout
        let toolchain = try await Toolchain.detect(store: self.store)
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
        let facts = FactProvider(source: source, loader: loader, toolchain: toolchain, preferred: preferred, mirrors: rootContext.mirrors)

        // Evaluate the root and split its dependencies into versioned ones and overrides.
        let root: Manifest
        switch rootContext.source {
        case .package(let directory):
            root = try await loader.load(packageAt: directory)
        case .xcode(let manifest):
            root = manifest
        }
        let rootReference = rootContext.reference
        let overrides = try await self.collectOverrides(
            root: root,
            mirrors: rootContext.mirrors,
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
            source: source,
            layout: layout
        )
        // The lockfile records original locations, so it stays valid without the mirrors.
        let lockedPins = pins.map { Pin(package: rootContext.mirrors.original($0.package), state: $0.state) }
        let resolved = ResolvedFile(pins: Dictionary(lockedPins.map { ($0.package.identity, $0) }, uniquingKeysWith: { $1 }), originHash: rootContext.originHash)
        try Self.writeResolvedFile(resolved, format: .forTools(root.parsedToolsVersion), to: layout.resolvedFile)

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
        mirrors: DependencyMirrors,
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
            guard let declaration = dependency.declaration.map(mirrors.effective) else {
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
    private static func checkoutsMatch(pins: [Pin], state: WorkspaceState, layout: Layout) -> Bool {
        pins.allSatisfy { pin in
            guard let managed = state.dependencies[pin.package.identity],
                  case .sourceControlCheckout(let checkedOut) = managed.state,
                  checkedOut == pin.state else {
                return false
            }
            return FileSystem.isDirectory(layout.checkoutsDirectory.appendingPathComponent(managed.subpath))
        }
    }

    /// Places every pinned tree into `.build/checkouts` and writes workspace state.
    private func materialize(
        pins: [Pin],
        fileSystemDependencies: [ManagedDependency],
        previous: WorkspaceState,
        source: GitSource,
        layout: Layout
    ) async throws -> Int {
        // Only touch checkouts whose revision changed or whose directory is missing.
        let stale = pins.filter { !Self.checkoutsMatch(pins: [$0], state: previous, layout: layout) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for pin in stale {
                group.addTask {
                    let tree = try await source.sourceTree(of: pin.package, revision: pin.state.revision)
                    let destination = layout.checkoutsDirectory.appendingPathComponent(pin.package.name)
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
            try FileSystem.removeTree(layout.checkoutsDirectory.appendingPathComponent(managed.subpath))
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
        try FileSystem.writeAtomically(try state.encode(), to: layout.workspaceState)
        return stale.count
    }

    // MARK: Files

    /// Writes only when the bytes change, and removes the file when there are no pins (like SwiftPM).
    private static func writeResolvedFile(_ file: ResolvedFile, format: ResolvedFile.FormatVersion, to url: URL) throws {
        guard !file.pins.isEmpty else {
            try FileSystem.removeTree(url)
            return
        }
        let data = try file.encode(format: format)
        guard FileSystem.readIfPresent(url) != data else { return }
        try FileSystem.writeAtomically(data, to: url)
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
