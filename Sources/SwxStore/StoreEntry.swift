import Foundation
import SwxSystem

/// An immutable, content-addressed part of the store that a remote cache can share.
public enum StoreEntry: Sendable, Hashable {
    /// An exported source tree, keyed by commit.
    case sourceTree(revision: String)
    /// The manifest files at a commit.
    case revisionManifests(revision: String)
    /// An extracted binary-target archive, keyed by its checksum.
    case artifact(checksum: String)
    /// A test target that passed with inputs hashing to this key.
    case testResult(key: String)

    /// Bumped when the layout of shared entries changes.
    private static let formatVersion = "v1"
    private static let archiveExtension = ".tar.gz"
    private static let jsonExtension = ".json"

    private enum Kind {
        static let trees = "trees"
        static let revisions = "revisions"
        static let artifacts = "artifacts"
        static let tests = "tests"
    }

    /// The entry's key in a remote cache.
    public var remoteKey: String {
        switch self {
        case .sourceTree(let revision):
            return [Self.formatVersion, Kind.trees, revision + Self.archiveExtension].joined(separator: "/")
        case .revisionManifests(let revision):
            return [Self.formatVersion, Kind.revisions, revision + Self.jsonExtension].joined(separator: "/")
        case .artifact(let checksum):
            return [Self.formatVersion, Kind.artifacts, checksum + Self.archiveExtension].joined(separator: "/")
        case .testResult(let key):
            return [Self.formatVersion, Kind.tests, key].joined(separator: "/")
        }
    }

    /// Directories travel as tar archives; files as they are.
    var isDirectory: Bool {
        switch self {
        case .sourceTree, .artifact:
            return true
        case .revisionManifests, .testResult:
            return false
        }
    }
}

extension Store {
    private enum Tar {
        static let executable = "tar"
        static let create = "-czf"
        /// pax keeps sub-second mtimes (GNU tar's default format rounds them to seconds), and
        /// SwiftPM's incremental builds compare mtimes exactly.
        static let preciseFormat = "--format=pax"
        static let extract = "-xzf"
        static let directory = "-C"
        static let everything = "."
    }

    private static let archiveName = "entry.tar.gz"

    public func localPath(of entry: StoreEntry) -> URL {
        switch entry {
        case .sourceTree(let revision):
            return self.sourceTreePath(revision: revision)
        case .revisionManifests(let revision):
            return self.revisionManifestsPath(revision: revision)
        case .artifact(let checksum):
            return self.artifactPath(checksum: checksum)
        case .testResult(let key):
            return self.testResultPath(key: key)
        }
    }

    public func contains(_ entry: StoreEntry) -> Bool {
        FileSystem.exists(self.localPath(of: entry))
    }

    /// A file holding the entry, to upload: the file itself, or a fresh archive of the directory.
    public func pack(_ entry: StoreEntry) async throws -> URL {
        let path = self.localPath(of: entry)
        guard entry.isDirectory else { return path }

        let archive = try self.makeTemporaryDirectory().appendingPathComponent(Self.archiveName)
        try await ProcessRunner.run([Tar.executable, Tar.preciseFormat, Tar.create, archive.path, Tar.directory, path.path, Tar.everything])
        return archive
    }

    /// Puts a downloaded entry in place. Trees are frozen read-only, as freshly exported ones are,
    /// and every entry appears atomically.
    public func unpack(_ entry: StoreEntry, from file: URL) async throws {
        let destination = self.localPath(of: entry)
        guard entry.isDirectory else {
            try FileSystem.writeAtomically(try FileSystem.read(file), to: destination)
            return
        }

        let staging = try self.makeTemporaryDirectory().appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        try FileSystem.createDirectory(staging)
        try await ProcessRunner.run([Tar.executable, Tar.extract, file.path, Tar.directory, staging.path])
        if case .sourceTree = entry {
            FileSystem.makeReadOnly(staging)
        }
        try FileSystem.moveIntoPlace(staging, destination)
    }
}
