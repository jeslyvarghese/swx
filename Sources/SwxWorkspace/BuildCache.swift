import Foundation
import SwxCore
import SwxManifest
import SwxSource
import SwxStore
import SwxSystem

/// Whether `swx cache` also copies the package's build outputs.
public enum BuildOutputs: Sendable {
    case include
    case exclude
}

/// Which archive a pull restored, or a push uploaded.
public enum BuildCacheMatch: Sendable, Equatable {
    /// Built from exactly these sources.
    case exact
    /// Built with the same dependencies; the package's own targets rebuild where they changed.
    case dependencies
}

/// What happened to the build outputs in a `swx cache pull|push --build`.
public enum BuildCacheOutcome: Sendable, Equatable {
    case restored(BuildCacheMatch, bytes: Int64)
    /// No archive for these inputs.
    case notCached
    /// `.build` already holds outputs, which a restore would overwrite.
    case keptLocal
    case uploaded([BuildCacheMatch], bytes: Int64)
    case alreadyCached
    /// Nothing has been built yet.
    case nothingBuilt
}

/// The two keys a build archive is stored under.
struct BuildCacheKeys: Equatable {
    let exact: String
    let dependencies: String

    static let formatVersion = "v1"
    private static let kind = "builds"
    private static let archiveExtension = ".tar.gz"

    func remoteKey(_ match: BuildCacheMatch) -> String {
        let key = match == .exact ? self.exact : self.dependencies
        return [Self.formatVersion, Self.kind, key + Self.archiveExtension].joined(separator: "/")
    }
}

extension Workspace {
    private enum BuildCache {
        /// Bumped whenever what goes into a key changes, so old archives stop matching.
        static let formatVersion = "swx-build-1"
        static let separator = "\u{0}"

        /// What swx and SwiftPM restore themselves (checkouts, downloads, state), and lock files.
        static let excluded = [
            WellKnownFile.checkoutsDirectory,
            "repositories",
            "registry",
            WellKnownFile.artifactsDirectory,
            WellKnownFile.workspaceState,
            ".lock",
        ]
        /// Present in a `.build` that holds no build outputs yet.
        static let bookkeeping: Set<String> = Set(Self.excluded + ["CACHEDIR.TAG", ".buildSystem_debug", ".buildSystem_release"])
    }

    private enum Tar {
        static let executable = "tar"
        static let create = "-czf"
        /// Sub-second mtimes survive (see StoreEntry).
        static let preciseFormat = "--format=pax"
        static let extract = "-xzf"
        static let directory = "-C"
        static let exclude = "--exclude"
        static let everything = "."
        static let memberPrefix = "./"
    }

    /// The keys of this package's build outputs. Both include the toolchain and the package's
    /// absolute path, because SwiftPM rebuilds everything when either differs; CI checks out at
    /// the same path every run. `exact` adds every file of the package; `dependencies` only the pins.
    func buildCacheKeys() async throws -> BuildCacheKeys {
        guard case .package(let directory) = self.options.root else {
            throw WorkspaceError(description: "build outputs are cached for packages")
        }
        let toolchain = try await Toolchain.detect(store: self.store)
        let root = try await self.rootContext()
        let shared = [
            BuildCache.formatVersion,
            toolchain.key,
            directory.standardizedFileURL.path,
            (try? ContentHash.sha256(fileAt: root.layout.resolvedFile)) ?? "",
        ].joined(separator: BuildCache.separator)

        return BuildCacheKeys(
            exact: ContentHash.sha256(shared + BuildCache.separator + Self.contentHash(of: directory)),
            dependencies: ContentHash.sha256(shared)
        )
    }

    /// Restores `.build` from the remote: the exact archive, else one built with the same pins.
    func pullBuild(from remote: RemoteStorage) async throws -> BuildCacheOutcome {
        let buildDirectory = try await self.buildDirectory()
        guard !Self.holdsBuildOutputs(buildDirectory) else { return .keptLocal }
        let keys = try await self.buildCacheKeys()

        let scratch = try self.store.makeTemporaryDirectory()
        defer { try? FileSystem.removeTree(scratch) }
        let archive = scratch.appendingPathComponent(UUID().uuidString)
        for match in [BuildCacheMatch.exact, .dependencies] {
            guard try await remote.download(keys.remoteKey(match), to: archive) else { continue }
            try FileSystem.createDirectory(buildDirectory)
            try await ProcessRunner.run([Tar.executable, Tar.extract, archive.path, Tar.directory, buildDirectory.path])
            return .restored(match, bytes: Self.fileSize(archive))
        }
        return .notCached
    }

    /// Uploads `.build` under the keys the remote doesn't have yet.
    func pushBuild(to remote: RemoteStorage) async throws -> BuildCacheOutcome {
        let buildDirectory = try await self.buildDirectory()
        guard Self.holdsBuildOutputs(buildDirectory) else { return .nothingBuilt }
        let keys = try await self.buildCacheKeys()

        var missing: [BuildCacheMatch] = []
        for match in [BuildCacheMatch.exact, .dependencies] where try await !remote.contains(keys.remoteKey(match)) {
            missing.append(match)
        }
        guard !missing.isEmpty else { return .alreadyCached }

        // One archive, uploaded under each missing key.
        let scratch = try self.store.makeTemporaryDirectory()
        defer { try? FileSystem.removeTree(scratch) }
        let archive = scratch.appendingPathComponent(UUID().uuidString)
        let exclusions = BuildCache.excluded.flatMap { [Tar.exclude, Tar.memberPrefix + $0] }
        try await ProcessRunner.run([Tar.executable, Tar.preciseFormat, Tar.create, archive.path] + exclusions + [Tar.directory, buildDirectory.path, Tar.everything])
        for match in missing {
            try await remote.upload(archive, as: keys.remoteKey(match))
        }
        return .uploaded(missing, bytes: Self.fileSize(archive))
    }

    private func buildDirectory() async throws -> URL {
        guard case .package(let directory) = self.options.root else {
            throw WorkspaceError(description: "build outputs are cached for packages")
        }
        return directory.appendingPathComponent(WellKnownFile.buildDirectory, isDirectory: true)
    }

    /// Whether `.build` has anything beyond checkouts and SwiftPM's bookkeeping.
    static func holdsBuildOutputs(_ buildDirectory: URL) -> Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: buildDirectory.path)) ?? []
        return entries.contains { !BuildCache.bookkeeping.contains($0) }
    }

    static func fileSize(_ file: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }
}
