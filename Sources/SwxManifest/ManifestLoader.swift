import Foundation
import SwxCore
import SwxStore
import SwxSystem

/// The running toolchain, discovered once and lazily (warm no-op runs never need it).
public struct Toolchain: Sendable, Hashable {
    private static let versionPrefix = "Swift version "

    /// `swift --version` output; part of every manifest cache key.
    public let versionDescription: String
    public let toolsVersion: ToolsVersion

    public init(versionDescription: String, toolsVersion: ToolsVersion) {
        self.versionDescription = versionDescription
        self.toolsVersion = toolsVersion
    }

    public static func detect() async throws -> Toolchain {
        let result = try await ProcessRunner.run(["swift", "--version"])
        let text = result.output + result.errorOutput
        return Toolchain(versionDescription: text, toolsVersion: Self.parseToolsVersion(text) ?? .v5_9)
    }

    /// `Apple Swift version 6.4 (swiftlang-…)` → 6.4.0
    static func parseToolsVersion(_ text: String) -> ToolsVersion? {
        guard let range = text.range(of: Self.versionPrefix) else { return nil }
        let token = text[range.upperBound...].prefix { $0.isNumber || $0 == "." }
        return ToolsVersion.parse(versionText: String(token))
    }
}

/// Loads manifests through a persistent, content-addressed cache.
///
/// The cache key covers the manifest text and the toolchain, so a hit is always valid:
/// the cache is memoization of a pure function `(manifest, toolchain) → Manifest`.
public actor ManifestLoader {
    private static let cacheFormatVersion = "1"
    private static let evaluationPrefix = "swx-manifest"

    private let store: Store
    private let toolchain: Toolchain
    private let limiter: ConcurrencyLimiter
    private var inFlight: [String: Task<Manifest, Error>] = [:]

    public init(store: Store, toolchain: Toolchain, maximumConcurrency: Int) {
        self.store = store
        self.toolchain = toolchain
        self.limiter = ConcurrencyLimiter(limit: maximumConcurrency)
    }

    /// Evaluates a manifest given its text (dependency manifests read from git).
    public func load(contents: String) async throws -> Manifest {
        let key = self.cacheKey(for: contents)

        // Memory, then disk, then evaluation.
        if let running = self.inFlight[key] {
            return try await running.value
        }
        let task = Task { [store, limiter] in
            if let cached = Self.readCache(store.manifestPath(key: key)) {
                return cached
            }
            let manifest = try await limiter.run { try await Self.evaluate(contents: contents) }
            try? FileSystem.writeAtomically(try JSONEncoder().encode(manifest), to: store.manifestPath(key: key))
            return manifest
        }
        self.inFlight[key] = task
        return try await task.value
    }

    /// Evaluates the manifest of a package on disk (roots and path dependencies).
    ///
    /// Keyed by content *and* location, since such manifests resolve relative paths.
    public func load(packageAt directory: URL) async throws -> Manifest {
        let manifestURL = directory.appendingPathComponent(WellKnownFile.manifest)
        let contents = String(decoding: try FileSystem.read(manifestURL), as: UTF8.self)
        let key = self.cacheKey(for: contents, location: directory.path)

        if let cached = Self.readCache(self.store.manifestPath(key: key)) {
            return cached
        }
        let manifest = try await self.limiter.run { try await Self.dumpPackage(at: directory) }
        try? FileSystem.writeAtomically(try JSONEncoder().encode(manifest), to: self.store.manifestPath(key: key))
        return manifest
    }

    // MARK: Evaluation

    /// Writes the manifest into a scratch package and asks SwiftPM to evaluate it.
    private static func evaluate(contents: String) async throws -> Manifest {
        let directory = try FileSystem.makeTemporaryDirectory(prefix: Self.evaluationPrefix)
        defer { try? FileSystem.removeTree(directory) }

        try Data(contents.utf8).write(to: directory.appendingPathComponent(WellKnownFile.manifest))
        return try await Self.dumpPackage(at: directory)
    }

    private static func dumpPackage(at directory: URL) async throws -> Manifest {
        let result = try await ProcessRunner.run(
            ["swift", "package", "dump-package", "--package-path", directory.path],
            exitPolicy: .allowFailure
        )
        guard result.succeeded else {
            let message = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ManifestError(description: message.isEmpty ? "manifest evaluation failed" : message)
        }
        return try DumpPackageDecoder.decode(result.standardOutput)
    }

    // MARK: Cache

    private func cacheKey(for contents: String, location: String = "") -> String {
        ContentHash.sha256([Self.cacheFormatVersion, self.toolchain.versionDescription, location, contents].joined(separator: "\u{0}"))
    }

    private static func readCache(_ url: URL) -> Manifest? {
        guard let data = FileSystem.readIfPresent(url) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }
}
