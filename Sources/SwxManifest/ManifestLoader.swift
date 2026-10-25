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

    private static let executable = "swift"

    /// The active toolchain. `swift --version` is only spawned when the fingerprint of the
    /// `swift` on PATH changes; the answer is cached in the store.
    public static func detect(store: Store = .default()) async throws -> Toolchain {
        let fingerprint = ExecutableLookup.fingerprint(of: Self.executable)
        let cacheURL = store.toolchainCachePath(fingerprint: ContentHash.sha256(fingerprint))
        if let cached = FileSystem.readIfPresent(cacheURL).map({ String(decoding: $0, as: UTF8.self) }), !cached.isEmpty {
            return Toolchain(versionDescription: cached, toolsVersion: Self.parseToolsVersion(cached) ?? .v5_9)
        }

        let result = try await ProcessRunner.run([Self.executable, "--version"])
        let text = result.output + result.errorOutput
        try? FileSystem.writeAtomically(Data(text.utf8), to: cacheURL)
        return Toolchain(versionDescription: text, toolsVersion: Self.parseToolsVersion(text) ?? .v5_9)
    }

    private enum TargetInfo {
        static let argument = "-print-target-info"
        static let target = "target"
        static let triple = "triple"
        static let unversionedTriple = "unversionedTriple"
        static let appleVendor = "-apple-"
        static let cacheSuffix = "\u{0}target-info"
    }

    /// The triple SwiftPM matches artifact bundles against: unversioned on Apple platforms
    /// (`arm64-apple-macosx`), the full triple elsewhere. Cached per toolchain fingerprint.
    public static func hostTriple(store: Store = .default()) async throws -> String {
        let fingerprint = ExecutableLookup.fingerprint(of: Self.executable)
        let cacheURL = store.toolchainCachePath(fingerprint: ContentHash.sha256(fingerprint + TargetInfo.cacheSuffix))
        if let cached = FileSystem.readIfPresent(cacheURL).map({ String(decoding: $0, as: UTF8.self) }), !cached.isEmpty {
            return cached
        }

        let result = try await ProcessRunner.run([Self.executable, TargetInfo.argument])
        guard let info = try? JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any],
              let target = info[TargetInfo.target] as? [String: Any],
              let unversioned = target[TargetInfo.unversionedTriple] as? String,
              let versioned = target[TargetInfo.triple] as? String else {
            throw ManifestError(description: "could not read the host triple from `swift \(TargetInfo.argument)`")
        }
        let triple = unversioned.contains(TargetInfo.appleVendor) ? unversioned : versioned
        try? FileSystem.writeAtomically(Data(triple.utf8), to: cacheURL)
        return triple
    }

    /// A short, stable key for cache paths that depend on the toolchain.
    public var key: String {
        String(ContentHash.sha256(self.versionDescription).prefix(Self.keyLength))
    }

    private static let keyLength = 8

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
    private static let cacheFormatVersion = "5"
    private static let evaluationPrefix = "swx-manifest"

    /// `SWX_STATIC_MANIFESTS=0` forces real evaluation for every manifest (for debugging).
    private static let staticParsingVariable = "SWX_STATIC_MANIFESTS"
    private static let disabledValue = "0"
    private static let usesStaticParsing = ProcessInfo.processInfo.environment[staticParsingVariable] != disabledValue

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
        let environment = CompilationEnvironment.host(compilerVersion: self.toolchain.toolsVersion)
        let task = Task { [store, limiter] in
            if let cached = Self.readCache(store.manifestPath(key: key)) {
                return cached
            }

            // Declarative manifests are read directly; only the rest pay for a compile.
            if Self.usesStaticParsing, let parsed = StaticManifestParser.parse(contents, environment: environment) {
                Trace.event("manifest: static parse")
                return parsed
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
        let environment = CompilationEnvironment.host(compilerVersion: self.toolchain.toolsVersion)
        if Self.usesStaticParsing, let parsed = StaticManifestParser.parse(contents, packageDirectory: directory, environment: environment) {
            return parsed
        }
        let manifest = try await self.limiter.run { try await Self.dumpPackage(at: directory) }
        try? FileSystem.writeAtomically(try JSONEncoder().encode(manifest), to: self.store.manifestPath(key: key))
        return manifest
    }

    // MARK: Evaluation

    /// Writes the manifest into a scratch package and asks SwiftPM to evaluate it.
    static func evaluate(contents: String) async throws -> Manifest {
        let directory = try FileSystem.makeTemporaryDirectory(prefix: Self.evaluationPrefix)
        defer { try? FileSystem.removeTree(directory) }

        try Data(contents.utf8).write(to: directory.appendingPathComponent(WellKnownFile.manifest))
        return try await Self.dumpPackage(at: directory)
    }

    /// Evaluates a manifest by compiling it against the toolchain's ManifestAPI (faster than
    /// starting SwiftPM), falling back to `dump-package`; `AppleProductTypes` apps need Xcode's
    /// ManifestAPI, since the command-line SwiftPM can't import that module.
    private static func dumpPackage(at directory: URL) async throws -> Manifest {
        let contents = String(decoding: try FileSystem.read(directory.appendingPathComponent(WellKnownFile.manifest)), as: UTF8.self)
        if ManifestCompiler.needsXcode(contents) {
            Trace.event("manifest: Xcode ManifestAPI")
            return try await ManifestCompiler.evaluate(contents: contents, packageDirectory: directory, api: .xcode)
        }
        do {
            let manifest = try await ManifestCompiler.evaluate(contents: contents, packageDirectory: directory, api: .toolchain)
            Trace.event("manifest: toolchain ManifestAPI")
            return manifest
        } catch {
            Trace.event("manifest: dump-package (\(String(describing: error).prefix(120)))")
            return try await Self.runDumpPackageDecoding(at: directory)
        }
    }

    /// Evaluation can fail transiently under heavy parallel load (SwiftPM's own cache locks), so try twice.
    private static let evaluationAttempts = 2

    /// `swift package dump-package`, decoded (the reference for parity checks).
    static func runDumpPackageDecoding(at directory: URL) async throws -> Manifest {
        var result = try await Self.runDumpPackage(at: directory)
        for _ in 1..<Self.evaluationAttempts where !result.succeeded {
            Trace.event("dump-package retry: \(result.errorOutput.prefix(200))")
            result = try await Self.runDumpPackage(at: directory)
        }
        guard result.succeeded else {
            let message = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ManifestError(description: message.isEmpty ? "manifest evaluation failed" : message)
        }
        return try DumpPackageDecoder.decode(result.standardOutput)
    }

    private static func runDumpPackage(at directory: URL) async throws -> ProcessResult {
        try await ProcessRunner.run(
            ["swift", "package", "dump-package", "--package-path", directory.path],
            exitPolicy: .allowFailure
        )
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
