import Foundation
import SwxStore
import SwxSystem

/// What a binary target provides, classified the way SwiftPM does.
public enum BinaryArtifactKind: Sendable, Hashable {
    case xcframework
    /// An `.artifactbundle`, with the type of each artifact inside (`executable`, `staticLibrary`, …).
    case artifactsArchive(types: [String])
}

/// The artifact found inside an extracted archive.
public struct DerivedArtifact: Sendable, Hashable {
    /// Relative to the archive's root, e.g. `Lottie.xcframework`.
    public let relativePath: String
    public let kind: BinaryArtifactKind
}

/// Downloads remote binary-target archives once per checksum into the shared store.
public actor BinaryArtifactSource {
    private let store: Store
    private let limiter: ConcurrencyLimiter
    private var downloads: [String: Task<URL, Error>] = [:]

    private enum Extension {
        static let zip = "zip"
        static let index = "artifactbundleindex"
        static let xcframework = "xcframework"
        static let artifactBundle = "artifactbundle"
    }

    private enum MetadataFile {
        static let xcframework = "info.plist"
        static let artifactBundle = "info.json"
    }

    private enum MetadataKey {
        static let availableLibraries = "AvailableLibraries"
        static let artifacts = "artifacts"
        static let type = "type"
    }

    private static let extractDirectory = "extract"

    public init(store: Store, maximumConcurrency: Int) {
        self.store = store
        self.limiter = ConcurrencyLimiter(limit: maximumConcurrency)
    }

    /// Zip archives, and `.artifactbundleindex` files that name one per host triple.
    public static func isSupported(url: String) -> Bool {
        Self.isArchive(url: url) || Self.isIndex(url: url)
    }

    public static func isArchive(url: String) -> Bool {
        URL(string: url)?.pathExtension.lowercased() == Extension.zip
    }

    public static func isIndex(url: String) -> Bool {
        URL(string: url)?.pathExtension.lowercased() == Extension.index
    }

    // MARK: Index files

    /// One archive listed by an `.artifactbundleindex`.
    public struct IndexedArchive: Sendable, Hashable {
        public let url: String
        public let checksum: String
    }

    private struct IndexFile: Decodable {
        struct Archive: Decodable {
            let fileName: String
            let checksum: String
            let supportedTriples: [String]
        }

        let archives: [Archive]
    }

    private static let parentDirectory = ".."

    /// SwiftPM's choice: the first zip archive listing the host triple, next to the index file.
    /// The index itself must match the manifest's checksum.
    public func indexedArchive(url: String, checksum: String, hostTriple: String) async throws -> IndexedArchive {
        guard let indexURL = URL(string: url) else {
            throw SourceError(description: "invalid binary target URL: \(url)")
        }
        let body = try await HTTP.data(from: indexURL)
        let actual = ContentHash.sha256(body)
        guard actual == checksum else {
            throw SourceError(description: "checksum of \(url) is \(actual), but the manifest expects \(checksum)")
        }
        let index: IndexFile
        do {
            index = try JSONDecoder().decode(IndexFile.self, from: body)
        } catch {
            throw SourceError(description: "\(url) is not a valid artifact bundle index: \(error)")
        }

        let candidate = index.archives.first { archive in
            Self.isArchive(url: archive.fileName) && archive.supportedTriples.contains(hostTriple)
        }
        guard let archive = candidate else {
            throw SourceError(description: "\(url) has no archive for '\(hostTriple)'")
        }
        guard !archive.fileName.contains(Self.parentDirectory) else {
            throw SourceError(description: "\(url) names an invalid archive '\(archive.fileName)'")
        }
        let archiveURL = indexURL.deletingLastPathComponent().appendingPathComponent(archive.fileName)
        return IndexedArchive(url: archiveURL.absoluteString, checksum: archive.checksum)
    }

    // MARK: Fetching

    /// The extracted archive for `checksum`, downloading and verifying it on first use.
    public func tree(url: String, checksum: String) async throws -> URL {
        let destination = self.store.artifactPath(checksum: checksum)
        defer { self.store.markUsed(destination) }
        if FileSystem.isDirectory(destination) {
            return destination
        }
        if let running = self.downloads[checksum] {
            return try await running.value
        }

        let task = Task { [store, limiter] in
            try await limiter.run { try await Self.download(url: url, checksum: checksum, store: store) }
        }
        self.downloads[checksum] = task
        return try await task.value
    }

    private static func download(url: String, checksum: String, store: Store) async throws -> URL {
        let staging = try store.makeTemporaryDirectory()
        defer { try? FileSystem.removeTree(staging) }

        // Download.
        guard let remote = URL(string: url) else {
            throw SourceError(description: "invalid binary target URL: \(url)")
        }
        let archive = staging.appendingPathComponent(remote.lastPathComponent)
        try await HTTP.download(remote, to: archive)

        // The manifest's checksum is the only thing vouching for these bytes.
        let actual = try ContentHash.sha256(fileAt: archive)
        guard actual == checksum else {
            throw SourceError(description: "checksum of \(url) is \(actual), but the manifest expects \(checksum)")
        }

        // Extract, refuse links that point outside the archive, then drop a wrapper directory.
        let extracted = staging.appendingPathComponent(Self.extractDirectory, isDirectory: true)
        try await ArchiveExtraction.unzip(archive, into: extracted)
        let root = Self.strippingWrapperDirectory(extracted)

        // Freeze and publish.
        FileSystem.makeReadOnly(root)
        let destination = store.artifactPath(checksum: checksum)
        try FileSystem.moveIntoPlace(root, destination)
        return destination
    }

    // MARK: Archive layout (mirrors SwiftPM's BinaryArtifactsManager)

    /// SwiftPM strips one level when the archive holds a single plain directory that
    /// itself contains the `.xcframework` / `.artifactbundle`.
    static func strippingWrapperDirectory(_ root: URL) -> URL {
        let directories = Self.subdirectories(of: root)
        guard directories.count == 1, let wrapper = directories.first else { return root }

        let wrapperExtension = wrapper.pathExtension
        guard !Self.isArtifactExtension(wrapperExtension) else { return root }
        guard Self.subdirectories(of: wrapper).contains(where: { Self.isArtifactExtension($0.pathExtension) }) else {
            return root
        }
        return wrapper
    }

    private static func isArtifactExtension(_ value: String) -> Bool {
        value == Extension.xcframework || value == Extension.artifactBundle
    }

    /// The single artifact in `root`, or `nil` when there is none or it is ambiguous
    /// (SwiftPM then reports or picks one itself).
    /// The artifact of a local binary target: SwiftPM takes the last one found when there are
    /// several (`deriveBinaryArtifact`).
    public static func deriveLocal(at root: URL) -> DerivedArtifact? {
        guard FileSystem.isDirectory(root) else { return nil }
        return Self.deriveAll(in: root, relativePath: "").last
    }

    public static func derive(in root: URL) -> DerivedArtifact? {
        let found = Self.deriveAll(in: root, relativePath: "")
        guard found.count == 1 else { return nil }
        return found.first
    }

    private static func deriveAll(in directory: URL, relativePath: String) -> [DerivedArtifact] {
        // Is this directory the artifact itself?
        if let kind = Self.kind(of: directory) {
            return [DerivedArtifact(relativePath: relativePath, kind: kind)]
        }

        // Otherwise search below it.
        var results: [DerivedArtifact] = []
        for subdirectory in Self.subdirectories(of: directory) {
            let name = subdirectory.lastPathComponent
            let childPath = relativePath.isEmpty ? name : relativePath + "/" + name
            results += Self.deriveAll(in: subdirectory, relativePath: childPath)
        }
        return results
    }

    /// An `Info.plist` listing libraries makes an XCFramework; an `info.json` listing artifacts, a bundle.
    private static func kind(of directory: URL) -> BinaryArtifactKind? {
        let files = Self.fileNames(in: directory)

        if let plist = files.first(where: { $0.lowercased() == MetadataFile.xcframework }),
           let data = FileSystem.readIfPresent(directory.appendingPathComponent(plist)),
           let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           object[MetadataKey.availableLibraries] is [Any] {
            return .xcframework
        }

        guard let json = files.first(where: { $0.lowercased() == MetadataFile.artifactBundle }),
              let data = FileSystem.readIfPresent(directory.appendingPathComponent(json)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let artifacts = object[MetadataKey.artifacts] as? [String: [String: Any]] else {
            return nil
        }

        // SwiftPM lists types in dictionary order; with mixed types that order isn't stable, so decline.
        let types = artifacts.values.compactMap { $0[MetadataKey.type] as? String }
        guard types.count == artifacts.count, Set(types).count <= 1 else { return nil }
        return .artifactsArchive(types: types)
    }

    // MARK: Helpers

    private static func subdirectories(of directory: URL) -> [URL] {
        Self.entries(of: directory).filter { FileSystem.isDirectory($0) && !Self.isSymlink($0) }
    }

    private static func fileNames(in directory: URL) -> [String] {
        Self.entries(of: directory).filter { !FileSystem.isDirectory($0) }.map(\.lastPathComponent)
    }

    private static func entries(of directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().map { directory.appendingPathComponent($0) }
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
