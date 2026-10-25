import Foundation
import SwxCore
import SwxManifest
import SwxSource
import SwxStore
import SwxSystem

/// A built command-line tool.
public struct BuiltTool: Sendable {
    public let name: String
    public let version: Version
    public let executable: URL
}

/// Builds and runs command-line tools from Swift packages (`uvx` / Mint for Swift).
///
/// Specs: `owner/repo[@version]`, a git URL with optional `@version`, or a well-known alias
/// (`swiftformat`, `swiftlint`, …). Builds are cached per revision and toolchain, and use the
/// tool's own committed `Package.resolved` when it has one.
public struct ToolRunner: Sendable {
    private enum Spec {
        static let versionSeparator: Character = "@"
        static let ownerSeparator: Character = "/"
        static let githubPrefix = "https://github.com/"
        static let gitSuffix = ".git"
        static let schemeSeparator = "://"
        static let scpPrefix = "git@"
        static let scpUser = "git"
    }

    private enum Layout {
        static let package = "package"
        static let metadata = "tool.json"
    }

    /// Popular tools, so `swx tool run swiftformat` just works.
    public static let aliases: [String: String] = [
        "swiftformat": "nicklockwood/SwiftFormat",
        "swiftlint": "realm/SwiftLint",
        "swift-format": "swiftlang/swift-format",
        "xcodegen": "yonaskolb/XcodeGen",
        "sourcery": "krzysztofzablocki/Sourcery",
        "swiftgen": "SwiftGen/SwiftGen",
        "periphery": "peripheryapp/periphery",
        "xcbeautify": "cpisciotta/xcbeautify",
        "tuist": "tuist/tuist",
        "mint": "yonaskolb/Mint",
    ]

    private let store: Store
    private let options: WorkspaceOptions

    public init(options: WorkspaceOptions) {
        self.options = options
        self.store = options.cacheDirectory.map(Store.init(root:)) ?? Store.default()
    }

    // MARK: Specs

    struct ParsedSpec: Equatable {
        let url: String
        let version: String?
        /// The name the user typed, to pick among several executables.
        let hint: String
    }

    static func parse(_ spec: String) -> ParsedSpec {
        // Split `name@version`, but leave the `@` of `git@host:…` alone.
        var name = spec
        var version: String?
        if let separator = spec.lastIndex(of: Spec.versionSeparator), spec[..<separator] != Spec.scpUser, spec.index(after: separator) < spec.endIndex {
            name = String(spec[..<separator])
            version = String(spec[spec.index(after: separator)...])
        }

        let resolved = Self.aliases[name.lowercased()] ?? name
        let url: String
        if resolved.contains(Spec.schemeSeparator) || resolved.hasPrefix(Spec.scpPrefix) {
            url = resolved
        } else if resolved.contains(Spec.ownerSeparator) {
            url = Spec.githubPrefix + resolved + Spec.gitSuffix
        } else {
            url = resolved
        }
        let hint = PackageIdentity.defaultName(fromLocation: name)
        return ParsedSpec(url: url, version: version, hint: hint)
    }

    // MARK: Building

    /// Builds the tool if needed and returns its executable.
    public func prepare(_ spec: String, executable requested: String?) async throws -> BuiltTool {
        let parsed = Self.parse(spec)
        let reference = PackageReference.remote(parsed.url)
        let toolchain = try await Toolchain.detect(store: self.store)

        // An exact version built before needs no network at all.
        if let exact = parsed.version.flatMap(Self.exactVersion),
           let cached = self.cachedBuild(reference.identity.description, version: exact, toolchainKey: toolchain.key, executable: requested) {
            return cached
        }

        let source = GitSource(store: self.store, maximumConcurrency: self.options.maximumConcurrency)

        // Pick the version: as requested, else the newest release.
        let tagged = try await source.versions(of: reference, toolsVersion: toolchain.toolsVersion)
        guard let chosen = Self.choose(parsed.version, from: tagged) else {
            throw WorkspaceError(description: "no release of \(parsed.url) matches '\(parsed.version ?? "latest")'")
        }

        // Cached build for this revision and toolchain?
        let directory = self.store.toolPath(name: reference.identity.description, revision: chosen.revision, toolchainKey: toolchain.key)
        let metadataURL = directory.appendingPathComponent(Layout.metadata)
        if let metadata = FileSystem.readIfPresent(metadataURL).flatMap({ try? JSONDecoder().decode(Metadata.self, from: $0) }),
           requested == nil || metadata.executable == requested,
           FileSystem.exists(URL(fileURLWithPath: metadata.binary)) {
            try self.index(reference.identity.description, version: chosen.version, toolchainKey: toolchain.key, metadata: metadataURL)
            return BuiltTool(name: metadata.executable, version: chosen.version, executable: URL(fileURLWithPath: metadata.binary))
        }

        // Check the sources out of the store into a private, writable package.
        let package = directory.appendingPathComponent(Layout.package, isDirectory: true)
        let tree = try await source.sourceTree(of: reference, revision: chosen.revision)
        try Materializer.materialize(tree, at: package)
        FileSystem.makeWritable(package)

        // Resolve with swx (honouring the tool's own Package.resolved), then build.
        let workspace = Workspace(options: WorkspaceOptions(
            root: .package(package),
            cacheDirectory: self.options.cacheDirectory,
            maximumConcurrency: self.options.maximumConcurrency,
            verbosity: self.options.verbosity,
            swiftPM: self.options.swiftPM
        ))
        _ = try await workspace.resolve(mode: .respectPins)

        let loader = ManifestLoader(store: self.store, toolchain: toolchain, maximumConcurrency: self.options.maximumConcurrency)
        let manifest = try await loader.load(packageAt: package)
        let executable = try Self.pickExecutable(in: manifest, requested: requested, hint: parsed.hint)

        let binary = try await ProductBuilder.build(product: executable, in: package, configuration: .release)
        try FileSystem.writeAtomically(try JSONEncoder().encode(Metadata(executable: executable, binary: binary.path)), to: metadataURL)

        try self.index(reference.identity.description, version: chosen.version, toolchainKey: toolchain.key, metadata: metadataURL)
        return BuiltTool(name: executable, version: chosen.version, executable: binary)
    }

    /// Records `name@version` → build, for network-free reuse of exact versions.
    private func index(_ name: String, version: Version, toolchainKey: String, metadata: URL) throws {
        let index = self.store.toolIndexPath(name: name, version: version.description, toolchainKey: toolchainKey)
        try FileSystem.writeAtomically(Data(metadata.path.utf8), to: index)
    }

    private func cachedBuild(_ name: String, version: Version, toolchainKey: String, executable requested: String?) -> BuiltTool? {
        let index = self.store.toolIndexPath(name: name, version: version.description, toolchainKey: toolchainKey)
        guard let metadataPath = FileSystem.readIfPresent(index).map({ String(decoding: $0, as: UTF8.self) }),
              let metadata = FileSystem.readIfPresent(URL(fileURLWithPath: metadataPath)).flatMap({ try? JSONDecoder().decode(Metadata.self, from: $0) }),
              requested == nil || metadata.executable == requested,
              FileSystem.exists(URL(fileURLWithPath: metadata.binary)) else {
            return nil
        }
        return BuiltTool(name: metadata.executable, version: version, executable: URL(fileURLWithPath: metadata.binary))
    }

    /// `1.2.3` exactly, `1.2` → newest `1.2.x`, nothing → newest release.
    static func choose(_ request: String?, from tagged: [TaggedVersion]) -> TaggedVersion? {
        let releases = tagged.filter { !$0.version.hasPrerelease }
        guard let request else {
            return releases.last
        }
        if let exact = Self.exactVersion(request) {
            return tagged.last { $0.version == exact }
        }
        let prefix = Self.withoutTagPrefix(request)
        return releases.last { $0.version.description.hasPrefix(prefix + ".") }
    }

    private static let tagPrefix = "v"

    /// A full `X.Y.Z` (optionally `v`-prefixed) is exact; a shorter request (`1.2`) means the
    /// newest release under it.
    static func exactVersion(_ request: String) -> Version? {
        Version(Self.withoutTagPrefix(request), parsing: .strict)
    }

    private static func withoutTagPrefix(_ request: String) -> String {
        request.hasPrefix(Self.tagPrefix) ? String(request.dropFirst(Self.tagPrefix.count)) : request
    }

    static func pickExecutable(in manifest: Manifest, requested: String?, hint: String) throws -> String {
        let executables = manifest.executableProductNames
        if let requested {
            guard executables.contains(requested) else {
                throw WorkspaceError(description: "\(manifest.name) has no executable '\(requested)' (available: \(executables.joined(separator: ", ")))")
            }
            return requested
        }
        if executables.count == 1, let only = executables.first {
            return only
        }
        if let match = executables.first(where: { $0.lowercased() == hint.lowercased() || $0.lowercased() == manifest.name.lowercased() }) {
            return match
        }
        throw WorkspaceError(description: "\(manifest.name) has several executables; pick one with --executable: \(executables.joined(separator: ", "))")
    }

    private struct Metadata: Codable {
        let executable: String
        let binary: String
    }

    // MARK: Installing

    /// Links the tool into `binDirectory` (default `~/.local/bin`).
    public func install(_ tool: BuiltTool, into binDirectory: URL) throws -> URL {
        try FileSystem.createDirectory(binDirectory)
        let link = binDirectory.appendingPathComponent(tool.name)
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool.executable)
        return link
    }

    /// Built tools in the cache, as `(directory name, executable)`.
    public func cached() -> [(String, String)] {
        let directory = self.store.toolsDirectory
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0 != "index" }
        return names.sorted().compactMap { name in
            let metadata = directory.appendingPathComponent(name).appendingPathComponent(Layout.metadata)
            guard let decoded = FileSystem.readIfPresent(metadata).flatMap({ try? JSONDecoder().decode(Metadata.self, from: $0) }) else { return nil }
            return (name, decoded.executable)
        }
    }
}
