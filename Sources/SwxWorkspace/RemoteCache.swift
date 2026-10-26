import Foundation
import SwxCore
import SwxManifest
import SwxSource
import SwxStore
import SwxSystem

/// What a `swx cache pull` or `push` did.
public struct CacheTransferReport: Sendable {
    /// Entries copied (downloaded or uploaded), and their total size in bytes.
    public var transferred = 0
    public var bytes: Int64 = 0
    /// Entries already on the receiving side.
    public var present = 0
    /// Entries the sending side doesn't have.
    public var unavailable = 0
}

/// Which way `swx cache` copies.
public enum CacheDirection: Sendable {
    case pull
    case push
}

extension Workspace {
    /// The environment variable naming the remote cache, when `--remote` isn't given.
    public static let remoteCacheVariable = "SWX_REMOTE_CACHE"

    /// Copies this project's store entries between the store and a remote cache, so a fresh
    /// machine (CI) restores checkouts, binary artifacts and test results without fetching or
    /// rebuilding: source trees and manifests of every pinned commit, artifacts the manifests
    /// declare, and the keys of `swx test --selective`.
    public func transferCache(_ direction: CacheDirection, remote location: String) async throws -> CacheTransferReport {
        let remote = try RemoteStorages.make(location)
        var report = CacheTransferReport()

        // Manifests first: on a pull they tell which artifacts there are.
        let revisions = try await self.pinnedRevisions()
        let manifests = revisions.map { StoreEntry.revisionManifests(revision: $0) }
        try await self.transfer(manifests, direction, remote: remote, into: &report)

        let trees = revisions.map { StoreEntry.sourceTree(revision: $0) }
        let artifacts = try await self.declaredArtifacts(revisions: revisions).map { StoreEntry.artifact(checksum: $0) }
        let tests = ((try? await self.testTargetKeys(arguments: [])) ?? [:]).values.sorted().map { StoreEntry.testResult(key: $0) }
        try await self.transfer(trees + artifacts + tests, direction, remote: remote, into: &report)
        return report
    }

    private static let transferConcurrency = 8

    /// Copies the entries the receiving side lacks, a few at a time.
    private func transfer(_ entries: [StoreEntry], _ direction: CacheDirection, remote: RemoteStorage, into report: inout CacheTransferReport) async throws {
        let store = self.store
        let results = try await withThrowingTaskGroup(of: (Outcome, Int64).self) { group in
            var outcomes: [(Outcome, Int64)] = []
            var pending = entries[...]

            // Keep a fixed number of transfers in flight.
            func startNext() {
                guard let entry = pending.popFirst() else { return }
                group.addTask { try await Self.transfer(entry, direction, store: store, remote: remote) }
            }
            for _ in 0..<Self.transferConcurrency {
                startNext()
            }
            while let outcome = try await group.next() {
                outcomes.append(outcome)
                startNext()
            }
            return outcomes
        }

        for (outcome, bytes) in results {
            switch outcome {
            case .transferred:
                report.transferred += 1
                report.bytes += bytes
            case .present:
                report.present += 1
            case .unavailable:
                report.unavailable += 1
            }
        }
    }

    private enum Outcome {
        case transferred
        case present
        case unavailable
    }

    private static func transfer(_ entry: StoreEntry, _ direction: CacheDirection, store: Store, remote: RemoteStorage) async throws -> (Outcome, Int64) {
        switch direction {
        case .pull:
            guard !store.contains(entry) else { return (.present, 0) }
            let scratch = try store.makeTemporaryDirectory()
            defer { try? FileSystem.removeTree(scratch) }
            let file = scratch.appendingPathComponent(UUID().uuidString)
            guard try await remote.download(entry.remoteKey, to: file) else { return (.unavailable, 0) }
            try await store.unpack(entry, from: file)
            return (.transferred, Self.size(of: file))

        case .push:
            guard store.contains(entry) else { return (.unavailable, 0) }
            guard try await !remote.contains(entry.remoteKey) else { return (.present, 0) }
            let file = try await store.pack(entry)
            defer {
                if file != store.localPath(of: entry) {
                    try? FileSystem.removeTree(file.deletingLastPathComponent())
                }
            }
            try await remote.upload(file, as: entry.remoteKey)
            return (.transferred, Self.size(of: file))
        }
    }

    private static func size(of file: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    // MARK: What the project uses

    /// The commit of every source-control pin in `Package.resolved` (registry and path pins have none).
    private func pinnedRevisions() async throws -> [String] {
        let root = try await self.rootContext()
        guard let data = FileSystem.readIfPresent(root.layout.resolvedFile) else {
            throw WorkspaceError(description: "no \(WellKnownFile.packageResolved); resolve first")
        }
        return try ResolvedFile.decode(data).pins.values.compactMap(\.state.revision).sorted()
    }

    /// Checksums of the remote binary targets the pinned manifests declare (from cached manifest files).
    private func declaredArtifacts(revisions: [String]) async throws -> [String] {
        let toolchain = try await Toolchain.detect(store: self.store)
        let loader = ManifestLoader(store: self.store, toolchain: toolchain, maximumConcurrency: self.options.maximumConcurrency)
        var checksums: Set<String> = []
        for revision in revisions {
            guard let data = FileSystem.readIfPresent(self.store.revisionManifestsPath(revision: revision)),
                  let files = try? JSONDecoder().decode(ManifestFiles.self, from: data),
                  let name = ToolsVersion.selectManifest(fileNames: files.rootFileNames, current: toolchain.toolsVersion, contentsOf: { files.files[$0] }),
                  let contents = files.files[name],
                  let manifest = try? await loader.load(contents: contents) else { continue }
            for target in manifest.targets {
                if case .remote(_, let checksum)? = target.binaryLocation {
                    checksums.insert(checksum)
                }
            }
        }
        return checksums.sorted()
    }
}
