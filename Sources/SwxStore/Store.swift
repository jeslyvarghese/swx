import Crypto
import Foundation
import SwxSystem

/// The global, content-addressed cache shared by every project.
///
/// Layout (under `~/.cache/swx` or `$XDG_CACHE_HOME/swx` or `$SWX_CACHE_DIR`):
/// ```
/// git/<name>-<hash>/     bare partial clones, one per repository URL
/// src/<revision>/        immutable exported source trees
/// manifests/<key>.json   evaluated manifest summaries
/// revisions/<sha>.json   root manifest files at a commit (commits are immutable)
/// ```
/// No other module knows this layout; everyone asks the store for paths.
public struct Store: Sendable {
    private enum Directory: String {
        case git
        case src
        case manifests
        case revisions
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
        self.directory(.src).appendingPathComponent(revision, isDirectory: true)
    }

    public func manifestPath(key: String) -> URL {
        self.directory(.manifests).appendingPathComponent(key).appendingPathExtension(Self.jsonExtension)
    }

    /// Manifest files at a commit; valid forever because a commit's contents never change.
    public func revisionManifestsPath(revision: String) -> URL {
        self.directory(.revisions).appendingPathComponent(revision).appendingPathExtension(Self.jsonExtension)
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
        SHA256.hash(data: data).map { Self.hexDigits[Int($0 >> 4)] + Self.hexDigits[Int($0 & 0x0F)] }.joined()
    }

    private static let hexDigits = (0..<16).map { String($0, radix: 16) }
}
