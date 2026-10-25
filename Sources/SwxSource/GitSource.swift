import Foundation
import SwxCore
import SwxStore
import SwxSystem

/// A package version and the commit it points to.
public struct TaggedVersion: Sendable, Hashable {
    public let version: Version
    public let revision: String

    public init(version: Version, revision: String) {
        self.version = version
        self.revision = revision
    }
}

/// Root-level manifest files at one revision (`Package.swift`, `Package@swift-*.swift`).
public struct ManifestFiles: Sendable, Codable {
    public let revision: String
    /// `file name → contents`, for manifest files only.
    public let files: [String: String]
    /// Every file name at the root, for manifest selection.
    public let rootFileNames: [String]
}

public struct SourceError: Error, CustomStringConvertible {
    public let description: String
}

/// Everything resolution needs from git repositories, with per-repository serialization
/// of mutating operations and deduplication of concurrent requests.
public actor GitSource {
    private let store: Store
    private let limiter: ConcurrencyLimiter

    /// In-flight or finished clone/fetch work, keyed by URL.
    private var repositoryReady: [String: Task<GitRepository, Error>] = [:]
    /// Tree exports in flight, keyed by revision.
    private var exports: [String: Task<URL, Error>] = [:]

    public init(store: Store, maximumConcurrency: Int) {
        self.store = store
        self.limiter = ConcurrencyLimiter(limit: maximumConcurrency)
    }

    // MARK: Versions

    /// The versions published as tags, mapped to commits the way SwiftPM does.
    ///
    /// Also starts the blobless clone in the background, since reading manifests will need it.
    public func versions(of package: PackageReference, toolsVersion: ToolsVersion) async throws -> [TaggedVersion] {
        let url = try Self.remoteURL(of: package)
        _ = self.repository(url: url, name: package.name)

        let tags = try await self.limiter.run { try await GitRepository.listRemoteTags(url: url) }
        return Self.versionMap(tags: tags, toolsVersion: toolsVersion)
    }

    /// Mirrors `Git.convertTagsToVersionMap`: version-specific tags (`1.0.0@swift-6`) win when present.
    static func versionMap(tags: [RemoteTag], toolsVersion: ToolsVersion) -> [TaggedVersion] {
        var known: [Version: String] = [:]
        var versionSpecific: [Version: String] = [:]

        for tag in tags {
            for key in toolsVersion.versionSpecificKeys where tag.name.hasSuffix(key) {
                if let version = Version(tag: String(tag.name.dropLast(key.count))), versionSpecific[version] == nil {
                    versionSpecific[version] = tag.revision
                }
                break
            }
            if let version = Version(tag: tag.name), known[version] == nil {
                known[version] = tag.revision
            }
        }

        let chosen = versionSpecific.isEmpty ? known : versionSpecific
        return chosen.map { TaggedVersion(version: $0.key, revision: $0.value) }.sorted { $0.version < $1.version }
    }

    public func resolveBranch(_ branch: String, of package: PackageReference) async throws -> String {
        let url = try Self.remoteURL(of: package)
        guard let revision = try await self.limiter.run({ try await GitRepository.resolveRemoteBranch(url: url, branch: branch) }) else {
            throw SourceError(description: "branch '\(branch)' not found in \(url)")
        }
        return revision
    }

    // MARK: Manifests

    /// Reads the manifest files at several revisions of one repository, with one blob download.
    public func manifestFiles(of package: PackageReference, at revisions: [String]) async throws -> [String: ManifestFiles] {
        // Commits are immutable: anything read before is still exact.
        var result: [String: ManifestFiles] = [:]
        for revision in Set(revisions) {
            guard let data = FileSystem.readIfPresent(self.store.revisionManifestsPath(revision: revision)),
                  let cached = try? JSONDecoder().decode(ManifestFiles.self, from: data) else { continue }
            result[revision] = cached
        }
        let uncached = Set(revisions).subtracting(result.keys)
        guard !uncached.isEmpty else { return result }

        let repository = try await self.ensureRevisions(Array(uncached), of: package)

        // List the root of every revision (local: trees are in the blobless clone).
        var listings: [String: [String: String]] = [:]
        for revision in uncached {
            listings[revision] = try await self.limiter.run { try await repository.rootFiles(at: revision) }
        }

        // Fetch every manifest blob across all revisions at once.
        let manifestBlobs = listings.values.flatMap { files in
            files.filter { Self.isManifestFile($0.key) }.map(\.value)
        }
        let blobs = try await self.limiter.run { try await repository.readBlobs(manifestBlobs) }

        // Assemble per-revision views and remember them.
        for (revision, files) in listings {
            var contents: [String: String] = [:]
            for (name, blob) in files where Self.isManifestFile(name) {
                contents[name] = blobs[blob].map { String(decoding: $0, as: UTF8.self) }
            }
            let manifestFiles = ManifestFiles(revision: revision, files: contents, rootFileNames: Array(files.keys))
            result[revision] = manifestFiles
            try? FileSystem.writeAtomically(try JSONEncoder().encode(manifestFiles), to: self.store.revisionManifestsPath(revision: revision))
        }
        return result
    }

    /// Manifest files of every revision seen so far (a free corpus for parity testing).
    public nonisolated func cachedManifestFiles() -> [ManifestFiles] {
        self.store.revisionManifestPaths().compactMap { url in
            FileSystem.readIfPresent(url).flatMap { try? JSONDecoder().decode(ManifestFiles.self, from: $0) }
        }
    }

    private static func isManifestFile(_ name: String) -> Bool {
        name == WellKnownFile.manifest
            || (name.hasPrefix(WellKnownFile.versionSpecificPrefix) && name.hasSuffix(WellKnownFile.swiftExtension))
    }

    // MARK: Source trees

    /// Starts exporting a tree that will probably be checked out, overlapping it with resolution.
    public func prefetchSourceTree(of package: PackageReference, revision: String) {
        guard self.exports[revision] == nil, !FileSystem.isDirectory(self.store.sourceTreePath(revision: revision)) else {
            return
        }
        self.exports[revision] = self.exportTask(of: package, revision: revision)
    }

    /// The immutable store tree for `revision`, exporting it on first use.
    public func sourceTree(of package: PackageReference, revision: String) async throws -> URL {
        let destination = self.store.sourceTreePath(revision: revision)
        if FileSystem.isDirectory(destination) {
            return destination
        }
        if let existing = self.exports[revision] {
            return try await existing.value
        }

        let task = self.exportTask(of: package, revision: revision)
        self.exports[revision] = task
        return try await task.value
    }

    private func exportTask(of package: PackageReference, revision: String) -> Task<URL, Error> {
        let destination = self.store.sourceTreePath(revision: revision)
        return Task { [store, limiter] in
            let repository = try await self.ensureRevisions([revision], of: package)

            // Export into staging (with submodules, like SwiftPM's checkouts), freeze it, then publish atomically.
            let staging = try store.makeTemporaryDirectory().appendingPathComponent(revision)
            try await limiter.run { try await repository.export(revision: revision, to: staging) }
            try await self.exportSubmodules(of: repository, revision: revision, into: staging)
            FileSystem.makeReadOnly(staging)
            try FileSystem.moveIntoPlace(staging, destination)
            return destination
        }
    }

    // MARK: Submodules

    /// `git submodule update --init --recursive`, from the store's blobless repositories.
    private func exportSubmodules(of repository: GitRepository, revision: String, into tree: URL) async throws {
        let submodules = try await repository.submodules(at: revision, exportedTo: tree)
        guard !submodules.isEmpty else { return }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for submodule in submodules {
                group.addTask {
                    let url = GitRepository.resolveSubmoduleURL(submodule.url, relativeTo: repository.url)
                    let child = try await self.ensureRevisions([submodule.commit], url: url, name: PackageIdentity.defaultName(fromLocation: url))
                    let destination = tree.appendingPathComponent(submodule.path, isDirectory: true)

                    try await self.limiter.run { try await child.export(revision: submodule.commit, to: destination) }
                    try await self.exportSubmodules(of: child, revision: submodule.commit, into: destination)
                }
            }
            try await group.waitForAll()
        }
    }

    // MARK: Repository lifecycle

    /// The repository, cloned if needed, and fetched if any revision is missing locally.
    private func ensureRevisions(_ revisions: [String], of package: PackageReference) async throws -> GitRepository {
        try await self.ensureRevisions(revisions, url: try Self.remoteURL(of: package), name: package.name)
    }

    private func ensureRevisions(_ revisions: [String], url: String, name: String) async throws -> GitRepository {
        let repository = try await self.repository(url: url, name: name).value

        // Fetch once if something is missing (new tags since the clone), sharing the work.
        guard try await !repository.missingCommits(revisions).isEmpty else {
            return repository
        }
        try await self.refresh(repository)

        // Commits no tag reaches (branch pins, submodule pins) are fetched by id.
        for missing in try await repository.missingCommits(revisions) {
            try await self.limiter.run { try await repository.fetchCommit(missing) }
        }
        if let missing = try await repository.missingCommits(revisions).first {
            throw SourceError(description: "revision \(missing) not found in \(url)")
        }
        return repository
    }

    private var refreshes: [String: Task<Void, Error>] = [:]

    private func refresh(_ repository: GitRepository) async throws {
        if let running = self.refreshes[repository.url] {
            return try await running.value
        }
        let task = Task { [limiter] in
            try await limiter.run { try await repository.fetch() }
        }
        self.refreshes[repository.url] = task
        defer { self.refreshes[repository.url] = nil }
        try await task.value
    }

    private func repository(url: String, name: String) -> Task<GitRepository, Error> {
        if let existing = self.repositoryReady[url] {
            return existing
        }
        let repository = GitRepository(url: url, path: self.store.repositoryPath(for: url, name: name))
        let task = Task { [store, limiter] in
            if !repository.exists {
                try await limiter.run { try await repository.clone(using: store) }
            }
            return repository
        }
        self.repositoryReady[url] = task
        return task
    }

    private static func remoteURL(of package: PackageReference) throws -> String {
        guard let url = package.kind.sourceControlLocation else {
            throw SourceError(description: "\(package.identity) is not a source-control package")
        }
        return url
    }
}
