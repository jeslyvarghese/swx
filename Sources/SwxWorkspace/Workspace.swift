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

/// SwiftPM's shared locations and credential settings (`--config-path`, `--security-path`, …),
/// so swx reads the same registries and mirrors and records the same fingerprints.
public struct SwiftPMSettings: Sendable {
    private enum Path {
        static let dotSwiftPM = ".swiftpm"
        static let configuration = "configuration"
        static let security = "security"
    }

    /// `~/.swiftpm/configuration`: shared `registries.json` and `mirrors.json`.
    public var configurationDirectory: URL
    /// `~/.swiftpm/security`: fingerprints.
    public var securityDirectory: URL
    /// `--netrc-file`; `nil` means `~/.netrc`.
    public var netrcFile: URL?
    public var credentialStore: CredentialStore

    /// Which store registry credentials come from (SwiftPM 6.4 consults exactly one).
    public enum CredentialStore: Sendable {
        /// The Keychain on macOS, the netrc file elsewhere.
        case platformDefault
        /// `--netrc`: the netrc file, even on macOS.
        case netrc
        /// `--disable-keychain`: on macOS, no stored credentials at all.
        case keychainDisabled
    }

    public init(
        configurationDirectory: URL? = nil,
        securityDirectory: URL? = nil,
        netrcFile: URL? = nil,
        credentialStore: CredentialStore = .platformDefault
    ) {
        let dotSwiftPM = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(Path.dotSwiftPM, isDirectory: true)
        self.configurationDirectory = configurationDirectory ?? dotSwiftPM.appendingPathComponent(Path.configuration, isDirectory: true)
        self.securityDirectory = securityDirectory ?? dotSwiftPM.appendingPathComponent(Path.security, isDirectory: true)
        self.netrcFile = netrcFile
        self.credentialStore = credentialStore
    }

    var credentials: CredentialSources {
        #if os(macOS)
        let store: CredentialSources.Store
        switch self.credentialStore {
        case .platformDefault:
            store = .keychain
        case .netrc:
            store = .netrc
        case .keychainDisabled:
            store = .none
        }
        return CredentialSources(netrcFile: self.netrcFile, store: store)
        #else
        return CredentialSources(netrcFile: self.netrcFile, store: .netrc)
        #endif
    }
}

public struct WorkspaceOptions: Sendable {
    public var root: WorkspaceRoot
    /// Overrides the shared cache location (otherwise `SWX_CACHE_DIR`, `XDG_CACHE_HOME`, `~/.cache/swx`).
    public var cacheDirectory: URL?
    public var maximumConcurrency: Int
    public var verbosity: Verbosity
    public var swiftPM: SwiftPMSettings
    public var registryTransformation: RegistryTransformation

    public init(
        root: WorkspaceRoot,
        cacheDirectory: URL?,
        maximumConcurrency: Int,
        verbosity: Verbosity,
        swiftPM: SwiftPMSettings = SwiftPMSettings(),
        registryTransformation: RegistryTransformation = .disabled
    ) {
        self.root = root
        self.cacheDirectory = cacheDirectory
        self.maximumConcurrency = maximumConcurrency
        self.verbosity = verbosity
        self.swiftPM = swiftPM
        self.registryTransformation = registryTransformation
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
        /// How paths inside the state file are spelled.
        let pathStyle: RecordedPathStyle

        var checkoutsDirectory: URL {
            self.stateDirectory.appendingPathComponent(WellKnownFile.checkoutsDirectory, isDirectory: true)
        }

        var workspaceState: URL {
            self.stateDirectory.appendingPathComponent(WellKnownFile.workspaceState)
        }

        var artifactsDirectory: URL {
            self.stateDirectory.appendingPathComponent(WellKnownFile.artifactsDirectory, isDirectory: true)
        }

        var registryDownloadsDirectory: URL {
            self.stateDirectory.appendingPathComponent(WellKnownFile.registryDownloadsDirectory, isDirectory: true)
        }

        /// Where a managed dependency's files live.
        func directory(of dependency: ManagedDependency) -> URL {
            switch dependency.state {
            case .registryDownload:
                return self.registryDownloadsDirectory.appendingPathComponent(dependency.subpath, isDirectory: true)
            case .sourceControlCheckout, .fileSystem:
                return self.checkoutsDirectory.appendingPathComponent(dependency.subpath, isDirectory: true)
            }
        }
    }

    /// The root's identity, origin hash, and how to obtain its manifest.
    private struct RootContext: Sendable {
        let reference: PackageReference
        let originHash: String
        let layout: Layout
        let source: RootSource
        let mirrors: DependencyMirrors
        let registries: RegistryConfiguration

        /// Where relative locations (like `Packages/`) are anchored.
        var directory: URL {
            switch self.source {
            case .package(let directory):
                return directory
            case .xcode:
                return self.layout.resolvedFile.deletingLastPathComponent()
            }
        }
    }

    private enum RootSource: Sendable {
        case package(URL)
        /// Xcode declares dependencies directly, plus package folders placed in the project,
        /// which are roots of the graph whose dependencies join the project's.
        case xcode(Manifest, rootPackages: [URL])
    }

    private static let xcodeConfigurationDirectory = "configuration"

    /// Xcode always writes `Package.resolved` v3.
    private static let xcodeToolsVersion = "6.0.0"

    private func rootContext() async throws -> RootContext {
        switch self.options.root {
        case .package(let directory):
            let buildDirectory = directory.appendingPathComponent(WellKnownFile.buildDirectory, isDirectory: true)
            return try Self.packageContext(directory, stateDirectory: buildDirectory, pathStyle: .lexical, settings: self.options.swiftPM)

        case .packageForXcode(let directory, let sourcePackages):
            // Same pins and origin hash as SwiftPM; only the checkout location (and Xcode's path spelling) differ.
            return try Self.packageContext(directory, stateDirectory: sourcePackages, pathStyle: .symlinksResolved, settings: self.options.swiftPM)

        case .xcodeProject(let url, let sourcePackages):
            let project = try await XcodeProjectReader.read(url)
            // Xcode keeps registries.json and mirrors.json next to the shared Package.resolved.
            let xcodeConfiguration = project.resolvedFile.deletingLastPathComponent().appendingPathComponent(Self.xcodeConfigurationDirectory, isDirectory: true)

            // Root packages count with their manifests: in the origin hash, and (by their lowest tools
            // version) in the lockfile format; Xcode alone writes v3.
            let rootManifests = try project.rootPackages.map {
                String(decoding: try FileSystem.read($0.appendingPathComponent(WellKnownFile.manifest)), as: UTF8.self)
            }
            let originHash = ContentHash.sha256(project.originHashContent(rootManifests: rootManifests))
            let toolsVersion = rootManifests.map { ToolsVersion.parse(manifest: $0) }.min()?.description ?? Self.xcodeToolsVersion

            // A local reference to a root package is the root itself, not a dependency.
            let rootIdentities = Set(project.rootPackages.map { PackageIdentity(location: $0.path) })
            let references = project.packageReferences.filter { reference in
                guard case .local(let path) = reference.location else { return true }
                return !rootIdentities.contains(PackageIdentity(location: path))
            }
            let manifest = Manifest(
                name: project.name,
                toolsVersion: toolsVersion,
                dependencies: references.map(Self.dependency),
                targets: [],
                products: [],
                traits: []
            )
            return RootContext(
                reference: PackageReference(identity: PackageIdentity(location: url.path), kind: .root(path: url.path)),
                originHash: originHash,
                layout: Layout(resolvedFile: project.resolvedFile, stateDirectory: sourcePackages, pathStyle: .symlinksResolved),
                source: .xcode(manifest, rootPackages: project.rootPackages),
                mirrors: DependencyMirrors.load(localDirectory: xcodeConfiguration, sharedDirectory: self.options.swiftPM.configurationDirectory),
                registries: try RegistryConfiguration.load(localDirectory: xcodeConfiguration, configurationDirectory: self.options.swiftPM.configurationDirectory)
            )
        }
    }

    /// SwiftPM: originHash is the SHA-256 of the root manifest's bytes.
    private static func packageContext(_ directory: URL, stateDirectory: URL, pathStyle: RecordedPathStyle, settings: SwiftPMSettings) throws -> RootContext {
        let manifestURL = directory.appendingPathComponent(WellKnownFile.manifest)
        guard let data = FileSystem.readIfPresent(manifestURL) else {
            throw WorkspaceError(description: "no \(WellKnownFile.manifest) found in \(directory.path)")
        }
        let layout = Layout(resolvedFile: directory.appendingPathComponent(WellKnownFile.packageResolved), stateDirectory: stateDirectory, pathStyle: pathStyle)
        return RootContext(
            reference: PackageReference(identity: PackageIdentity(location: directory.path), kind: .root(path: directory.path)),
            originHash: ContentHash.sha256(data),
            layout: layout,
            source: .package(directory),
            mirrors: DependencyMirrors.load(for: directory, sharedDirectory: settings.configurationDirectory),
            registries: try RegistryConfiguration.load(packageDirectory: directory, configurationDirectory: settings.configurationDirectory)
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
            let pins = resolvedFile.pins.values.map { Pin(package: root.mirrors.effective($0.package), state: $0.state, originalLocation: $0.originalLocation) }
            if Self.checkoutsMatch(pins: pins, state: state, layout: layout) {
                return ResolveReport(outcome: .upToDate, pins: pins, changes: [], materialized: 0)
            }
            let concurrency = self.options.maximumConcurrency
            let toolchain = try await Toolchain.detect(store: self.store)
            let loader = ManifestLoader(store: self.store, toolchain: toolchain, maximumConcurrency: concurrency)
            let materialized = try await self.materialize(
                pins: pins,
                fileSystemDependencies: [],
                root: try await self.rootManifest(root, loader: loader),
                rootReference: root.reference,
                previous: state,
                context: MaterializeContext(
                    source: GitSource(store: self.store, maximumConcurrency: concurrency),
                    registry: self.registrySource(for: root),
                    loader: loader,
                    toolsVersion: toolchain.toolsVersion,
                    mirrors: root.mirrors,
                    layout: layout
                )
            )
            return ResolveReport(outcome: .restoredFromPins, pins: pins, changes: [], materialized: materialized)
        }

        let previousPins = resolvedFile?.pins ?? [:]

        // SwiftPM's precomputation: if the pins still satisfy every requirement, the solver needs
        // nothing but the pins, so no repository has to list its tags.
        if mode == .respectPins, !previousPins.isEmpty {
            do {
                let catalog = VersionCatalog.pinned(Self.pinnedVersions(previousPins, mirrors: root.mirrors))
                return try await self.fullResolve(mode: mode, root: root, previousPins: previousPins, previousState: state, catalog: catalog)
            } catch let miss as PinsNoLongerFit {
                self.log(.verbose, "pins need resolving: \(miss.reason)")
            }
        }

        // Full resolution.
        return try await self.fullResolve(mode: mode, root: root, previousPins: previousPins, previousState: state, catalog: .remote)
    }

    /// The registry client for this root's configuration, recording fingerprints where SwiftPM does.
    private func registrySource(for root: RootContext) -> RegistrySource {
        RegistrySource(
            store: self.store,
            configuration: root.registries,
            credentials: RegistryCredentials(sources: self.options.swiftPM.credentials),
            fingerprints: self.fingerprints,
            signingEntities: SigningEntityStore(securityDirectory: self.options.swiftPM.securityDirectory),
            maximumConcurrency: self.options.maximumConcurrency,
            warn: { message in FileHandle.standardError.write(Data("warning: \(message)\n".utf8)) }
        )
    }

    /// SwiftPM's fingerprint store, shared with it.
    private var fingerprints: FingerprintStore {
        FingerprintStore(securityDirectory: self.options.swiftPM.securityDirectory)
    }

    /// Registry versions carry no commit; the solver only reads the version.
    private static let registryRevision = ""

    /// Version pins keyed by the identity resolution uses (the mirror's, when mirrored).
    private static func pinnedVersions(_ pins: [PackageIdentity: Pin], mirrors: DependencyMirrors) -> [PackageIdentity: TaggedVersion] {
        var result: [PackageIdentity: TaggedVersion] = [:]
        for pin in pins.values {
            switch pin.state {
            case .version(let version, let revision):
                result[mirrors.effective(pin.package).identity] = TaggedVersion(version: version, revision: revision)
            case .registryVersion(let version):
                result[pin.package.identity] = TaggedVersion(version: version, revision: Self.registryRevision)
            case .branch, .revision:
                continue
            }
        }
        return result
    }

    private func fullResolve(
        mode: ResolveMode,
        root rootContext: RootContext,
        previousPins: [PackageIdentity: Pin],
        previousState: WorkspaceState,
        catalog: VersionCatalog
    ) async throws -> ResolveReport {
        let layout = rootContext.layout
        let toolchain = try await Toolchain.detect(store: self.store)
        let concurrency = self.options.maximumConcurrency
        let source = GitSource(store: self.store, maximumConcurrency: concurrency)
        let loader = ManifestLoader(store: self.store, toolchain: toolchain, maximumConcurrency: concurrency)
        // Prefer pinned versions unless updating.
        var preferred: [PackageIdentity: Version] = [:]
        if mode == .respectPins {
            preferred = Self.pinnedVersions(previousPins, mirrors: rootContext.mirrors).mapValues(\.version)
        }
        let registry = self.registrySource(for: rootContext)
        let facts = FactProvider(
            source: source,
            registry: registry,
            loader: loader,
            toolchain: toolchain,
            preferred: preferred,
            mirrors: rootContext.mirrors,
            catalog: catalog,
            transformation: self.options.registryTransformation
        )

        // Evaluate the root and split its dependencies into versioned ones and overrides.
        let root = await facts.transform(try await self.rootManifest(rootContext, loader: loader))
        let rootReference = rootContext.reference
        let overrides = try await self.collectOverrides(
            root: root,
            packageDirectory: rootContext.directory,
            editedDependencies: previousState.editedDependencies,
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
        let bindings: [ResolvedBinding]
        do {
            bindings = try await self.drive(&solver, facts: facts)
        } catch let failure as ResolutionFailure {
            // With only the pins on offer, a conflict just means the pins no longer fit.
            guard case .remote = catalog else { throw PinsNoLongerFit(reason: failure.description) }
            throw WorkspaceError(description: "Dependency resolution failed:\n\(failure.description)")
        }

        // Turn bindings and overrides into pins.
        var pins: [Pin] = []
        for binding in bindings {
            if case .registry = binding.package.kind {
                // A registry package that replaced a git dependency remembers that URL, as SwiftPM does.
                let original = await registry.scmURL(forIdentity: binding.package.identity)
                pins.append(Pin(package: binding.package, state: .registryVersion(binding.version), originalLocation: original))
                continue
            }
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
            root: root,
            rootReference: rootReference,
            previous: previousState,
            context: MaterializeContext(
                source: source,
                registry: registry,
                loader: loader,
                toolsVersion: toolchain.toolsVersion,
                mirrors: rootContext.mirrors,
                layout: layout
            )
        )
        // The lockfile records original locations, so it stays valid without the mirrors.
        let lockedPins = pins.map { Pin(package: rootContext.mirrors.original($0.package), state: $0.state, originalLocation: $0.originalLocation) }
        let resolved = ResolvedFile(pins: Dictionary(lockedPins.map { ($0.package.identity, $0) }, uniquingKeysWith: { $1 }), originHash: rootContext.originHash)
        try Self.writeResolvedFile(resolved, format: .forTools(root.parsedToolsVersion), to: layout.resolvedFile)

        return ResolveReport(
            outcome: .resolved,
            pins: pins,
            changes: Self.changes(from: previousPins, to: resolved.pins),
            materialized: materialized
        )
    }

    private func rootManifest(_ context: RootContext, loader: ManifestLoader) async throws -> Manifest {
        switch context.source {
        case .package(let directory):
            return try await loader.load(packageAt: directory)
        case .xcode(var manifest, let rootPackages):
            // Root packages' dependencies are the project's too.
            for package in rootPackages {
                manifest.dependencies += try await loader.load(packageAt: package).dependencies
            }
            return manifest
        }
    }

    // MARK: Solver loop

    private func drive(_ solver: inout Solver, facts: FactProvider) async throws -> [ResolvedBinding] {
        while true {
            switch solver.resume() {
            case .solved(let bindings):
                return bindings

            case .failed(let failure):
                throw ResolutionFailure(description: failure.description)

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

    /// The solver proved the requirements unsatisfiable with the versions it was offered.
    private struct ResolutionFailure: Error {
        let description: String
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
            case .edited(let previous):
                // SwiftPM keeps an edited package's pin in Package.resolved.
                return previous
            case .fileSystem:
                return nil
            }
        }

        var isEdited: Bool {
            guard case .edited = self.state else { return false }
            return true
        }

        var fileSystemDependency: ManagedDependency? {
            guard case .fileSystem(let path, let manifestName) = self.state else { return nil }

            // SwiftPM records path dependencies under their identity, named after their manifest.
            return ManagedDependency(package: self.package, state: .fileSystem(path: path), subpath: self.package.identity.description, name: manifestName)
        }
    }

    private enum OverrideState: Sendable {
        case branch(String, revision: String)
        case revision(String)
        case fileSystem(path: String, manifestName: String)
        /// Under `swift package edit`: used from its editable copy, owned by SwiftPM.
        case edited(previousPin: Pin?)
    }

    /// `swift package edit` puts editable copies here unless `--path` is given.
    private static let editedPackagesDirectory = "Packages"

    private struct Overrides {
        var rootDependencies: [DependencyDeclaration] = []
        var overridden: [PackageIdentity: Override] = [:]
    }

    /// Fixes unversioned root dependencies outside the solver and lifts their dependencies to the root.
    private func collectOverrides(
        root: Manifest,
        packageDirectory: URL,
        editedDependencies: [PackageIdentity: EditedDependency],
        mirrors: DependencyMirrors,
        mode: ResolveMode,
        previousPins: [PackageIdentity: Pin],
        source: GitSource,
        loader: ManifestLoader,
        facts: FactProvider
    ) async throws -> Overrides {
        var result = Overrides()
        var pending = root.requiredDependencies(role: .root)

        // Edited packages override every requirement on them and contribute their copy's dependencies.
        for (identity, edited) in editedDependencies {
            guard let previous = previousPins[identity] else { continue }
            let path = edited.path ?? packageDirectory.appendingPathComponent(Self.editedPackagesDirectory).appendingPathComponent(edited.subpath).path
            let manifest = await facts.transform(try await loader.load(packageAt: URL(fileURLWithPath: path)))
            result.overridden[identity] = Override(package: mirrors.effective(previous.package), state: .edited(previousPin: previous))
            pending += manifest.requiredDependencies(role: .dependency)
        }

        while !pending.isEmpty {
            let dependency = pending.removeFirst()
            let declaration = mirrors.effective(dependency.declaration)
            let identity = declaration.package.identity
            await facts.noteTraits(dependency.traits, for: identity)
            guard result.overridden[identity]?.isEdited != true else { continue }

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
                manifest = try await Self.manifest(of: declaration.package, at: revision, source: source, loader: loader, toolsVersion: facts.toolsVersion)
            case (.revision(let revision), _):
                override = Override(package: declaration.package, state: .revision(revision))
                manifest = try await Self.manifest(of: declaration.package, at: revision, source: source, loader: loader, toolsVersion: facts.toolsVersion)
            case (_, .fileSystem(let path)):
                manifest = try await loader.load(packageAt: URL(fileURLWithPath: path))
                override = Override(package: declaration.package, state: .fileSystem(path: path, manifestName: manifest.name))
            default:
                throw WorkspaceError(description: "unsupported requirement for \(identity): \(declaration.requirement)")
            }
            result.overridden[identity] = override
            pending += await facts.transform(manifest).requiredDependencies(role: .dependency)
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

    /// The manifest SwiftPM would use at `revision`, honouring version-specific manifests.
    private static func manifest(
        of package: PackageReference,
        at revision: String,
        source: GitSource,
        loader: ManifestLoader,
        toolsVersion: ToolsVersion
    ) async throws -> Manifest {
        guard let files = try await source.manifestFiles(of: package, at: [revision])[revision],
              let name = ToolsVersion.selectManifest(fileNames: files.rootFileNames, current: toolsVersion, contentsOf: { files.files[$0] }),
              let contents = files.files[name] else {
            throw WorkspaceError(description: "no Package.swift in \(package.identity) at \(revision)")
        }
        return try await loader.load(contents: contents)
    }

    // MARK: Checkouts

    /// The state entry SwiftPM records for a pin (names come from manifests, filled in later).
    private static func managedDependency(for pin: Pin, name: String? = nil) -> ManagedDependency {
        guard case .registryVersion(let version) = pin.state else {
            return ManagedDependency(package: pin.package, state: .sourceControlCheckout(pin.state), subpath: pin.package.name, name: name)
        }

        // `.build/registry/downloads/<scope>/<name>/<version>`, named by identity rather than manifest.
        // (Registry identities always have both parts; the registry client rejects others.)
        let identity = pin.package.identity
        guard let (scope, name) = identity.registryComponents else {
            return ManagedDependency(package: pin.package, state: .registryDownload(version, scmURL: pin.originalLocation), subpath: identity.description + Self.subpathSeparator + version.description)
        }
        let subpath = [scope, name, version.description].joined(separator: Self.subpathSeparator)
        return ManagedDependency(package: pin.package, state: .registryDownload(version, scmURL: pin.originalLocation), subpath: subpath)
    }

    private static let subpathSeparator = "/"

    /// Are all pins already in place (checked out or downloaded) at the right versions?
    private static func checkoutsMatch(pins: [Pin], state: WorkspaceState, layout: Layout) -> Bool {
        let preserved = state.preservedIdentities
        return pins.allSatisfy { pin in
            // Edited (and other SwiftPM-managed) dependencies are not ours to check out.
            if preserved.contains(pin.package.identity) {
                return true
            }
            let wanted = Self.managedDependency(for: pin)
            guard let managed = state.dependencies[pin.package.identity], managed.state == wanted.state else {
                return false
            }
            return FileSystem.isDirectory(layout.directory(of: managed))
        }
    }

    /// What materializing needs from the resolve that preceded it.
    private struct MaterializeContext: Sendable {
        let source: GitSource
        let registry: RegistrySource
        let loader: ManifestLoader
        let toolsVersion: ToolsVersion
        let mirrors: DependencyMirrors
        let layout: Layout
    }

    /// A finished piece of materialization work.
    private enum MaterializeWork: Sendable {
        case checkout
        case package(PackageIdentity, name: String, PackageArtifacts)
    }

    /// Places every pinned tree into `.build/checkouts` or `.build/registry/downloads`, binary
    /// artifacts into `.build/artifacts`, and writes workspace state.
    private func materialize(
        pins: [Pin],
        fileSystemDependencies: [ManagedDependency],
        root: Manifest,
        rootReference: PackageReference,
        previous: WorkspaceState,
        context: MaterializeContext
    ) async throws -> Int {
        let layout = context.layout
        let preserved = previous.preservedIdentities
        let installer = ArtifactInstaller(
            source: BinaryArtifactSource(store: self.store, maximumConcurrency: self.options.maximumConcurrency),
            artifactsDirectory: layout.artifactsDirectory,
            pathStyle: layout.pathStyle,
            mirrors: context.mirrors,
            previous: previous,
            hostTriple: { [store] in try await Toolchain.hostTriple(store: store) }
        )

        // Only touch trees whose version changed or whose directory is missing.
        let stale = pins.filter { !Self.checkoutsMatch(pins: [$0], state: previous, layout: layout) }

        // Place trees, and meanwhile read each package's manifest (for its name and binary targets)
        // and fetch its artifacts, so downloads overlap with checkouts.
        let work = try await withThrowingTaskGroup(of: MaterializeWork.self) { group in
            for pin in stale {
                group.addTask {
                    try await self.place(pin, context: context)
                    return .checkout
                }
            }

            // Edited packages are SwiftPM's.
            for pin in pins where !preserved.contains(pin.package.identity) {
                group.addTask {
                    let manifest = try await Self.manifest(of: pin, context: context)
                    let change: PackageChange = previous.dependencies[pin.package.identity]?.state == Self.managedDependency(for: pin).state ? .unchanged : .updated
                    let artifacts = try await installer.install(package: pin.package, manifest: manifest, change: change)
                    return .package(pin.package.identity, name: manifest.name, artifacts)
                }
            }

            for dependency in fileSystemDependencies {
                group.addTask {
                    let manifest = try await context.loader.load(packageAt: URL(fileURLWithPath: dependency.package.kind.location))
                    let artifacts = try await installer.install(package: dependency.package, manifest: manifest, change: .unchanged)
                    return .package(dependency.package.identity, name: manifest.name, artifacts)
                }
            }

            group.addTask {
                let artifacts = try await installer.install(package: rootReference, manifest: root, change: .unchanged)
                return .package(rootReference.identity, name: root.name, artifacts)
            }

            return try await group.reduce(into: [MaterializeWork]()) { $0.append($1) }
        }

        // Collect manifest names and artifact outcomes.
        var names: [PackageIdentity: String] = [:]
        var artifacts: [PackageArtifacts] = []
        for case .package(let identity, let name, let packageArtifacts) in work {
            names[identity] = name
            artifacts.append(packageArtifacts)
            for case (let key, .leftToSwiftPM(let reason)) in packageArtifacts.outcomes {
                self.log(.verbose, "artifact \(key.package)/\(key.targetName) left to SwiftPM: \(reason)")
            }
        }

        // Record the new state. SwiftPM names checkouts after their manifest, registry packages by identity.
        var state = previous
        state.dependencies = [:]
        for pin in pins {
            state.dependencies[pin.package.identity] = Self.managedDependency(for: pin, name: names[pin.package.identity])
        }
        for dependency in fileSystemDependencies {
            state.dependencies[dependency.package.identity] = dependency
        }

        // Remove trees of packages that are gone or moved to another version.
        for (identity, managed) in previous.dependencies where state.dependencies[identity]?.subpath != managed.subpath {
            switch managed.state {
            case .sourceControlCheckout:
                try FileSystem.removeTree(layout.directory(of: managed))
            case .registryDownload:
                try FileSystem.removeTree(layout.directory(of: managed))
                Self.removeEmptyParents(of: layout.directory(of: managed), upTo: layout.registryDownloadsDirectory)
            case .fileSystem:
                continue
            }
        }

        try installer.record(artifacts, into: &state)
        try FileSystem.writeAtomically(try state.encode(), to: layout.workspaceState)
        return stale.count
    }

    /// Puts one pinned tree in place from the store.
    private func place(_ pin: Pin, context: MaterializeContext) async throws {
        let managed = Self.managedDependency(for: pin)
        let destination = context.layout.directory(of: managed)

        switch pin.state {
        case .registryVersion(let version):
            let tree = try await context.registry.sourceTree(of: pin.package.identity, version: version)
            let strategy = try Materializer.materialize(tree, at: destination)

            // SwiftPM keeps the release's provenance next to the sources.
            let metadata = try await context.registry.releaseMetadataFile(of: pin.package.identity, version: version)
            try FileSystem.writeAtomically(metadata, to: destination.appendingPathComponent(WellKnownFile.registryMetadata))
            self.log(.verbose, "downloaded \(pin.package.identity) \(version) (\(strategy))")

        case .version(let version, let revision):
            // Like SwiftPM, a tag must keep pointing at the commit first seen for it.
            if case .remoteSourceControl(let url) = pin.package.kind {
                try await self.fingerprints.verifyRevision(pin.package.identity, url: url, version: version.description, revision: revision)
            }
            let tree = try await context.source.sourceTree(of: pin.package, revision: revision)
            let strategy = try Materializer.materialize(tree, at: destination)
            self.log(.verbose, "checked out \(pin.package.identity) \(pin.state) (\(strategy))")

        case .branch(_, let revision), .revision(let revision):
            let tree = try await context.source.sourceTree(of: pin.package, revision: revision)
            let strategy = try Materializer.materialize(tree, at: destination)
            self.log(.verbose, "checked out \(pin.package.identity) \(pin.state) (\(strategy))")
        }
    }

    /// The manifest of a pinned package, from the registry or from git.
    private static func manifest(of pin: Pin, context: MaterializeContext) async throws -> Manifest {
        guard let revision = pin.state.revision else {
            guard case .registryVersion(let version) = pin.state else {
                throw WorkspaceError(description: "\(pin.package.identity) has no revision")
            }
            let contents = try await context.registry.manifest(of: pin.package.identity, version: version, toolsVersion: context.toolsVersion)
            return try await context.loader.load(contents: contents)
        }
        return try await Self.manifest(of: pin.package, at: revision, source: context.source, loader: context.loader, toolsVersion: context.toolsVersion)
    }

    /// Drops directories left empty between `directory` and `root` (old `<scope>/<name>`).
    private static func removeEmptyParents(of directory: URL, upTo root: URL) {
        var current = directory.deletingLastPathComponent()
        while current.path.count > root.path.count {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: current.path), contents.isEmpty else { return }
            try? FileSystem.removeTree(current)
            current = current.deletingLastPathComponent()
        }
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
