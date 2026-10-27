import Foundation
import SwxSource
import SwxStore

public typealias StoreSection = SwxStore.StoreSection
public typealias StoreSectionSize = SwxStore.StoreSectionSize
public typealias StorePruneReport = SwxStore.StorePruneReport
public typealias PruneEffect = SwxStore.PruneEffect

/// The kinds of file a remote cache holds, by the second part of their keys (`v1/trees/…`).
public enum RemoteCacheSection: String, CaseIterable, Sendable, CustomStringConvertible {
    case trees
    case revisions
    case artifacts
    case tests
    case builds
    /// Anything else under the location: older formats, or files swx didn't write.
    case other

    public var description: String {
        switch self {
        case .trees: return "source trees"
        case .revisions: return "manifests at commits"
        case .artifacts: return "binary artifacts"
        case .tests: return "passed tests"
        case .builds: return "build outputs"
        case .other: return "other files"
        }
    }

    private static let keySeparator: Character = "/"
    private static let kindComponent = 1

    init(key: String) {
        let components = key.split(separator: Self.keySeparator)
        guard components.count > Self.kindComponent, let section = RemoteCacheSection(rawValue: String(components[Self.kindComponent])) else {
            self = .other
            return
        }
        self = section
    }
}

/// How large one kind of remote file is, in total.
public struct RemoteSectionSize: Sendable, Equatable {
    public let section: RemoteCacheSection
    public let entries: Int
    public let bytes: Int64
}

/// What `swx cache prune --remote` removed (or would remove).
public struct RemotePruneReport: Sendable, Equatable {
    public var removed: [RemoteSectionSize] = []
    public var kept = 0

    public var entries: Int {
        self.removed.reduce(0) { $0 + $1.entries }
    }

    public var bytes: Int64 {
        self.removed.reduce(0) { $0 + $1.bytes }
    }
}

/// `swx cache size` and `swx cache prune`: the store and remote caches, with no project involved.
public struct CacheMaintenance: Sendable {
    let store: Store

    public init(cacheDirectory: URL?) {
        self.store = cacheDirectory.map(Store.init(root:)) ?? Store.default()
    }

    public var storeLocation: URL {
        self.store.root
    }

    // MARK: Local store

    public func sizes() -> [StoreSectionSize] {
        self.store.sizes()
    }

    /// Removes what no live project pins and nothing used within `age`.
    public func prune(unusedFor age: TimeInterval, effect: PruneEffect) throws -> StorePruneReport {
        try self.store.prune(unusedFor: age, effect: effect)
    }

    // MARK: Remote cache

    public func remoteSizes(_ location: String) async throws -> [RemoteSectionSize] {
        let objects = try await RemoteStorages.make(location).list(prefix: "")
        return Self.group(objects).sorted { $0.bytes > $1.bytes }
    }

    /// Deletes remote files last written (or, in a directory, last downloaded) before `age` ago.
    /// Whatever a project still needs is uploaded again by its next `swx cache push`.
    public func pruneRemote(_ location: String, unusedFor age: TimeInterval, effect: PruneEffect, now: Date = Date()) async throws -> RemotePruneReport {
        let remote = try RemoteStorages.make(location)
        let objects = try await remote.list(prefix: "")
        // Only files swx wrote: a directory remote may hold other things.
        let expired = objects.filter { RemoteCacheSection(key: $0.key) != .other && now.timeIntervalSince($0.modified) >= age }

        if effect == .apply {
            for object in expired {
                try await remote.delete(object.key)
            }
        }
        return RemotePruneReport(removed: Self.group(expired), kept: objects.count - expired.count)
    }

    private static func group(_ objects: [RemoteObject]) -> [RemoteSectionSize] {
        var totals: [RemoteCacheSection: (entries: Int, bytes: Int64)] = [:]
        for object in objects {
            let section = RemoteCacheSection(key: object.key)
            let current = totals[section] ?? (0, 0)
            totals[section] = (current.entries + 1, current.bytes + object.bytes)
        }
        return RemoteCacheSection.allCases.compactMap { section in
            totals[section].map { RemoteSectionSize(section: section, entries: $0.entries, bytes: $0.bytes) }
        }
    }
}
