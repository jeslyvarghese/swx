import Crypto
import Foundation
import SwxSystem

/// The global, content-addressed cache shared by every project.
///
/// Layout (under `~/.cache/swx` or `$XDG_CACHE_HOME/swx` or `$SWX_CACHE_DIR`):
/// ```
/// git/<name>-<hash>/     bare partial clones, one per repository URL
/// trees/<revision>/      immutable exported source trees, submodules included
/// manifests/<key>.json   evaluated manifest summaries
/// revisions/<sha>.json   root manifest files at a commit (commits are immutable)
/// artifacts/<checksum>/  extracted binary-target archives, keyed by their SHA-256
/// registry/<checksum>/   extracted registry source archives, keyed by their SHA-256
/// releases/<key>.json    registry release metadata (released versions never change)
/// tools/<key>/           built command-line tools (`swx tool run`)
/// scripts/<key>/         generated packages for single-file scripts (`swx run file.swift`)
/// cas/                   shared compilation cache, when the toolchain supports it
/// index/packages.json    the Swift Package Index's package list (`swx add <name>`)
/// tests/<hash>           test targets that passed with exactly these inputs (`swx test --selective`)
/// ```
/// No other module knows this layout; everyone asks the store for paths.
public struct Store: Sendable {
    private enum Directory: String {
        case git
        /// Renamed from `src` when trees started including submodules, so older trees aren't reused.
        case sourceTrees = "trees"
        case manifests
        case revisions
        case artifacts
        case registry
        case releases
        case tools
        case scripts
        case toolchains
        case cas
        case index
        case tests
        case temporary = "tmp"
    }

    private enum Environment {
        static let cacheOverride = "SWX_CACHE_DIR"
        static let xdgCacheHome = "XDG_CACHE_HOME"
    }

    private static let applicationDirectory = "swx"
    private static let fallbackCacheDirectory = ".cache"
    private static let jsonExtension = "json"
    private static let shortHashLength = 8

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Resolves the store location from the environment.
    public static func `default`() -> Store {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment[Environment.cacheOverride], !override.isEmpty {
            return Store(root: URL(fileURLWithPath: override, isDirectory: true))
        }
        if let xdg = environment[Environment.xdgCacheHome], !xdg.isEmpty {
            return Store(root: URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent(Self.applicationDirectory))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Store(root: home.appendingPathComponent(Self.fallbackCacheDirectory).appendingPathComponent(Self.applicationDirectory))
    }

    // MARK: Paths

    /// A bare repository for `url`, named readably but keyed by the full URL.
    public func repositoryPath(for url: String, name: String) -> URL {
        let key = String(ContentHash.sha256(url).prefix(Self.shortHashLength))
        return self.directory(.git).appendingPathComponent("\(name)-\(key)", isDirectory: true)
    }

    /// The immutable source tree exported at `revision`.
    public func sourceTreePath(revision: String) -> URL {
        self.directory(.sourceTrees).appendingPathComponent(revision, isDirectory: true)
    }

    public func manifestPath(key: String) -> URL {
        self.directory(.manifests).appendingPathComponent(key).appendingPathExtension(Self.jsonExtension)
    }

    /// Manifest files at a commit; valid forever because a commit's contents never change.
    public func revisionManifestsPath(revision: String) -> URL {
        self.directory(.revisions).appendingPathComponent(revision).appendingPathExtension(Self.jsonExtension)
    }

    /// The extracted contents of a binary-target archive; the checksum pins its bytes forever.
    public func artifactPath(checksum: String) -> URL {
        self.directory(.artifacts).appendingPathComponent(checksum, isDirectory: true)
    }

    /// The extracted source archive of a registry release.
    public func registryTreePath(checksum: String) -> URL {
        self.directory(.registry).appendingPathComponent(checksum, isDirectory: true)
    }

    /// The source archive itself, kept so its signature can be checked whenever it is placed.
    public func registryArchivePath(checksum: String) -> URL {
        self.directory(.registry).appendingPathComponent(checksum).appendingPathExtension(Self.zipExtension)
    }

    private static let zipExtension = "zip"
    /// Bumped when the cached release format gains fields (2: signatures).
    private static let releaseFormat = "2"

    /// Cached metadata of one release, keyed by registry, identity and version.
    public func registryReleasePath(registry: String, identity: String, version: String) -> URL {
        let key = ContentHash.sha256([Self.releaseFormat, registry, identity.lowercased(), version].joined(separator: "\u{0}"))
        return self.directory(.releases).appendingPathComponent(key).appendingPathExtension(Self.jsonExtension)
    }

    /// A tool built from `revision` with one toolchain.
    public func toolPath(name: String, revision: String, toolchainKey: String) -> URL {
        self.directory(.tools).appendingPathComponent("\(name)-\(revision.prefix(Self.shortHashLength))-\(toolchainKey)", isDirectory: true)
    }

    /// Remembers which built tool an exact `name@version` maps to, so it starts without network.
    public func toolIndexPath(name: String, version: String, toolchainKey: String) -> URL {
        self.directory(.tools).appendingPathComponent(Self.indexDirectory, isDirectory: true)
            .appendingPathComponent("\(name)@\(version)-\(toolchainKey)")
    }

    private static let indexDirectory = "index"

    public var toolsDirectory: URL {
        self.directory(.tools)
    }

    /// The generated package for a script, keyed by script content and toolchain.
    public func scriptPath(key: String) -> URL {
        self.directory(.scripts).appendingPathComponent(key, isDirectory: true)
    }

    /// The content-addressed compilation cache shared by all builds.
    public var compilationCachePath: URL {
        self.directory(.cas)
    }

    /// `swift --version` output for a toolchain fingerprint.
    public func toolchainCachePath(fingerprint: String) -> URL {
        self.directory(.toolchains).appendingPathComponent(fingerprint)
    }

    /// Every cached per-revision manifest record.
    public func revisionManifestPaths() -> [URL] {
        let directory = self.directory(.revisions)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().map { directory.appendingPathComponent($0) }
    }

    /// A fresh scratch directory inside the store (same volume, so renames are atomic).
    public func makeTemporaryDirectory() throws -> URL {
        let url = self.directory(.temporary).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileSystem.createDirectory(url)
        return url
    }

    /// The Swift Package Index's list of package URLs, refreshed daily.
    public var packageIndexPath: URL {
        self.directory(.index).appendingPathComponent(Self.packageIndexFile)
    }

    private static let packageIndexFile = "packages.json"

    /// A marker that a test target passed with inputs hashing to `key`.
    public func testResultPath(key: String) -> URL {
        self.directory(.tests).appendingPathComponent(key)
    }

    private func directory(_ directory: Directory) -> URL {
        self.root.appendingPathComponent(directory.rawValue, isDirectory: true)
    }
}

/// Hashing used for cache keys and `originHash`.
public enum ContentHash {
    public static func sha256(_ text: String) -> String {
        Self.sha256(Data(text.utf8))
    }

    public static func sha256(_ data: Data) -> String {
        Self.hex(SHA256.hash(data: data))
    }

    private static let fileChunkSize = 1 << 20

    /// Hashes a file in chunks, so large archives never sit in memory whole.
    public static func sha256(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: Self.fileChunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Self.hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { Self.hexDigits[Int($0 >> 4)] + Self.hexDigits[Int($0 & 0x0F)] }.joined()
    }

    private static let hexDigits = (0..<16).map { String($0, radix: 16) }
}
