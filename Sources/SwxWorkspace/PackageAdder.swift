import Foundation
import SwxCore
import SwxManifest
import SwxSource
import SwxSystem

/// Which version `swx add` asks for.
public enum AddRequirement: Sendable {
    /// The newest release, up to the next major version (`from:`).
    case latest
    /// `from:` this version.
    case from(String)
    case exact(String)
    case branch(String)
}

/// `swx add <package>`: what to add, and to which target.
public struct AddRequest: Sendable {
    /// A URL, `owner/repo` (GitHub), or a package name looked up in the Swift Package Index.
    public var package: String
    public var requirement: AddRequirement
    public var product: String?
    public var target: String?

    public init(package: String, requirement: AddRequirement, product: String?, target: String?) {
        self.package = package
        self.requirement = requirement
        self.product = product
        self.target = target
    }
}

/// What `swx add` did.
public struct AddResult: Sendable {
    public let url: String
    public let identity: String
    /// `from: "1.8.2"`, `exact: "1.0.0"`, `branch: "main"`; `nil` when the package was already a dependency.
    public let requirement: String?
    public let product: String
    public let target: String
    /// The target already used the product; nothing was edited.
    public let alreadyPresent: Bool
}

extension Workspace {
    private enum Spec {
        static let gitHubBase = "https://github.com/"
        static let schemeSeparator = "://"
        static let sshPrefix = "git@"
        static let pathSeparator: Character = "/"
    }

    private enum PackageCommand {
        static let swift = "swift"
        static let package = "package"
        static let packagePath = "--package-path"
        static let addDependency = "add-dependency"
        static let addTargetDependency = "add-target-dependency"
        static let packageOption = "--package"
        static let from = "--from"
        static let exact = "--exact"
        static let branch = "--branch"
    }

    /// Adds a package dependency and one of its products to a target, through SwiftPM's own
    /// manifest editor. The caller resolves afterwards.
    public func add(_ request: AddRequest, status: (String) -> Void) async throws -> AddResult {
        guard case .package(let directory) = self.options.root else {
            throw WorkspaceError(description: "swx add works on packages; add packages to Xcode projects in Xcode")
        }
        let toolchain = try await Toolchain.detect(store: self.store)
        let loader = ManifestLoader(store: self.store, toolchain: toolchain, maximumConcurrency: self.options.maximumConcurrency)
        let root = try await loader.load(packageAt: directory)

        // Which repository, and is it already a dependency?
        let url = try await self.locate(request.package, status: status)
        let identity = PackageIdentity(location: url).description
        let declared = root.dependencies.first { $0.identity == identity }

        // The version to ask for, and the manifest there (for its products).
        let reference = PackageReference.remote(url)
        let source = GitSource(store: self.store, maximumConcurrency: self.options.maximumConcurrency)
        let (requirement, arguments, revision) = try await Self.choose(request.requirement, of: reference, source: source, toolsVersion: toolchain.toolsVersion)
        let manifest = try await Self.manifest(of: reference, at: revision, source: source, loader: loader, toolsVersion: toolchain.toolsVersion)
        let product = try Self.product(request.product, of: manifest, identity: identity)
        let target = try Self.target(request.target, of: root)

        // Nothing to do when the target already uses the product.
        let uses = root.targets.first { $0.name == target }?.dependencies ?? []
        let alreadyUsed = uses.contains { dependency in
            guard case .product(let name, let package, _) = dependency else { return false }
            return name == product && package?.lowercased() == identity
        }
        guard !alreadyUsed else {
            return AddResult(url: url, identity: identity, requirement: nil, product: product, target: target, alreadyPresent: true)
        }

        // SwiftPM edits the manifest, so formatting follows its conventions.
        let packagePath = [PackageCommand.packagePath, directory.path]
        if declared == nil {
            try await ProcessRunner.run([PackageCommand.swift, PackageCommand.package] + packagePath + [PackageCommand.addDependency, url] + arguments)
        }
        try await ProcessRunner.run([PackageCommand.swift, PackageCommand.package] + packagePath
            + [PackageCommand.addTargetDependency, product, target, PackageCommand.packageOption, declared?.referenceName ?? identity])
        return AddResult(url: url, identity: identity, requirement: declared == nil ? requirement : nil, product: product, target: target, alreadyPresent: false)
    }

    // MARK: Package

    /// A URL as given; `owner/repo` on GitHub; or a name, through the Swift Package Index.
    private func locate(_ spec: String, status: (String) -> Void) async throws -> String {
        if spec.contains(Spec.schemeSeparator) || spec.hasPrefix(Spec.sshPrefix) {
            return spec
        }
        if spec.split(separator: Spec.pathSeparator).count == 2 {
            return Spec.gitHubBase + spec
        }

        status("looking up \(spec) in the Swift Package Index")
        let index = PackageIndex(store: self.store)
        let candidates = try await index.candidates(named: spec)
        guard !candidates.isEmpty else {
            throw WorkspaceError(description: "no package named \(spec) in the Swift Package Index; pass its URL or owner/repo")
        }
        guard let url = await index.preferred(among: candidates) else {
            throw WorkspaceError(description: "several packages are named \(spec): \(candidates.joined(separator: ", ")); pass owner/repo")
        }
        return url
    }

    // MARK: Version

    /// The requirement text, `add-dependency`'s flags for it, and the commit to read the manifest at.
    private static func choose(
        _ requirement: AddRequirement,
        of reference: PackageReference,
        source: GitSource,
        toolsVersion: ToolsVersion
    ) async throws -> (String, [String], String) {
        switch requirement {
        case .branch(let branch):
            let revision = try await source.resolveBranch(branch, of: reference)
            return ("branch: \"\(branch)\"", [PackageCommand.branch, branch], revision)

        case .latest:
            let versions = try await source.versions(of: reference, toolsVersion: toolsVersion)
            guard let newest = versions.filter({ !$0.version.hasPrerelease }).max(by: { $0.version < $1.version }) else {
                throw WorkspaceError(description: "\(reference.identity) has no releases; add it with --branch")
            }
            let text = newest.version.description
            return ("from: \"\(text)\"", [PackageCommand.from, text], newest.revision)

        case .from(let text):
            let release = try await Self.release(text, of: reference, source: source, toolsVersion: toolsVersion)
            return ("from: \"\(text)\"", [PackageCommand.from, text], release.revision)

        case .exact(let text):
            let release = try await Self.release(text, of: reference, source: source, toolsVersion: toolsVersion)
            return ("exact: \"\(text)\"", [PackageCommand.exact, text], release.revision)
        }
    }

    /// A version that must exist as a release.
    private static func release(_ text: String, of reference: PackageReference, source: GitSource, toolsVersion: ToolsVersion) async throws -> TaggedVersion {
        let versions = try await source.versions(of: reference, toolsVersion: toolsVersion)
        guard let wanted = Version(text), let release = versions.first(where: { $0.version == wanted }) else {
            throw WorkspaceError(description: "\(reference.identity) has no version \(text)")
        }
        return release
    }

    private static func manifest(of package: PackageReference, at revision: String, source: GitSource, loader: ManifestLoader, toolsVersion: ToolsVersion) async throws -> Manifest {
        guard let files = try await source.manifestFiles(of: package, at: [revision])[revision],
              let name = ToolsVersion.selectManifest(fileNames: files.rootFileNames, current: toolsVersion, contentsOf: { files.files[$0] }),
              let contents = files.files[name] else {
            throw WorkspaceError(description: "no \(WellKnownFile.manifest) in \(package.identity) at \(revision)")
        }
        return try await loader.load(contents: contents)
    }

    // MARK: Product and target

    private static let swiftPrefix = "swift-"

    /// The product asked for; else the only library; else the library named like the package.
    private static func product(_ requested: String?, of manifest: Manifest, identity: String) throws -> String {
        if let requested {
            guard manifest.products.contains(where: { $0.name == requested }) else {
                throw WorkspaceError(description: "\(identity) has no product \(requested); it has \(manifest.products.map(\.name).joined(separator: ", "))")
            }
            return requested
        }

        let libraries = manifest.products.filter { $0.kind == .library }.map(\.name)
        if libraries.count == 1, let only = libraries.first {
            return only
        }
        // `swift-collections` → `Collections`: compare letters and digits, without a `swift-` prefix.
        let simplified = { (name: String) -> String in
            let lowered = name.lowercased()
            let unprefixed = lowered.hasPrefix(Self.swiftPrefix) ? String(lowered.dropFirst(Self.swiftPrefix.count)) : lowered
            return unprefixed.filter { $0.isLetter || $0.isNumber }
        }
        let packageNames = [simplified(manifest.name), simplified(identity)]
        if let named = libraries.first(where: { packageNames.contains(simplified($0)) }) {
            return named
        }

        // `swift-log` → `Logging`: the one library whose name starts with the package's.
        let prefixed = libraries.filter { library in packageNames.contains { !$0.isEmpty && simplified(library).hasPrefix($0) } }
        if prefixed.count == 1, let only = prefixed.first {
            return only
        }
        throw WorkspaceError(description: "\(identity) has several libraries (\(libraries.joined(separator: ", "))); pick one with --product")
    }

    /// The target asked for; else the package's only non-test target.
    private static func target(_ requested: String?, of root: Manifest) throws -> String {
        let candidates = root.targets.filter { $0.kind != .test && $0.kind != .binary && $0.kind != .system }.map(\.name)
        if let requested {
            guard root.targets.contains(where: { $0.name == requested }) else {
                throw WorkspaceError(description: "no target \(requested); targets: \(root.targets.map(\.name).joined(separator: ", "))")
            }
            return requested
        }
        guard candidates.count == 1, let only = candidates.first else {
            throw WorkspaceError(description: "pick a target with --target: \(candidates.joined(separator: ", "))")
        }
        return only
    }
}
