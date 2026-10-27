import Foundation
import SwxSystem

/// A part of the store, as `swx cache size` and `swx cache prune` report it.
public enum StoreSection: String, CaseIterable, Sendable, CustomStringConvertible {
    case repositories
    case sourceTrees
    case registry
    case artifacts
    case tools
    case scripts
    case tests
    case manifests
    case revisions
    case releases
    case toolchains
    case compilationCache
    case prebuilts
    case packageIndex
    case temporary

    var directory: Store.Directory {
        switch self {
        case .repositories: return .git
        case .sourceTrees: return .sourceTrees
        case .registry: return .registry
        case .artifacts: return .artifacts
        case .tools: return .tools
        case .scripts: return .scripts
        case .tests: return .tests
        case .manifests: return .manifests
        case .revisions: return .revisions
        case .releases: return .releases
        case .toolchains: return .toolchains
        case .compilationCache: return .cas
        case .prebuilts: return .prebuilts
        case .packageIndex: return .index
        case .temporary: return .temporary
        }
    }

    public var description: String {
        switch self {
        case .repositories: return "git repositories"
        case .sourceTrees: return "source trees"
        case .registry: return "registry releases"
        case .artifacts: return "binary artifacts"
        case .tools: return "built tools"
        case .scripts: return "built scripts"
        case .tests: return "passed tests"
        case .manifests: return "evaluated manifests"
        case .revisions: return "manifests at commits"
        case .releases: return "registry metadata"
        case .toolchains: return "toolchain fingerprints"
        case .compilationCache: return "compilation cache"
        case .prebuilts: return "prebuilt libraries"
        case .packageIndex: return "package index"
        case .temporary: return "scratch"
        }
    }

    /// How `swx cache prune` treats the section's entries.
    var pruning: Pruning {
        switch self {
        case .repositories, .sourceTrees, .registry, .artifacts, .prebuilts, .tools, .scripts, .tests:
            return .whenUnused
        case .temporary:
            return .whenStale
        case .manifests, .revisions, .releases, .toolchains, .compilationCache, .packageIndex:
            return .never
        }
    }

    enum Pruning {
        /// Removed when no live project pins it and it wasn't used within the age given.
        case whenUnused
        /// Scratch left by interrupted runs: removed once a day old.
        case whenStale
        /// Small metadata that makes later resolves fast, or a cache the compiler manages.
        case never
    }
}

/// How large one section of the store is.
public struct StoreSectionSize: Sendable, Equatable {
    public let section: StoreSection
    public let entries: Int
    public let bytes: Int64
}

/// What one resolved project pins, so `swx cache prune` keeps it however long ago it was used.
public struct StoreProject: Codable, Sendable, Equatable {
    /// The project's `Package.resolved`; the record is dropped once that file is gone.
    public let resolvedFile: String
    /// Commits checked out from the store's source trees.
    public let revisions: [String]
    /// Repository URLs those commits come from.
    public let repositories: [String]

    public init(resolvedFile: String, revisions: [String], repositories: [String]) {
        self.resolvedFile = resolvedFile
        self.revisions = revisions.sorted()
        self.repositories = repositories.sorted()
    }
}

/// Whether a prune removes anything, or only reports what it would.
public enum PruneEffect: Sendable {
    case apply
    case dryRun
}

/// What `swx cache prune` removed (or would remove), per section.
public struct StorePruneReport: Sendable, Equatable {
    public var removed: [StoreSection: StoreSectionSize] = [:]
    /// Project records dropped because their `Package.resolved` is gone.
    public var forgottenProjects = 0

    public var entries: Int {
        self.removed.values.reduce(0) { $0 + $1.entries }
    }

    public var bytes: Int64 {
        self.removed.values.reduce(0) { $0 + $1.bytes }
    }

    mutating func add(_ section: StoreSection, bytes: Int64) {
        let current = self.removed[section]
        self.removed[section] = StoreSectionSize(section: section, entries: (current?.entries ?? 0) + 1, bytes: (current?.bytes ?? 0) + bytes)
    }
}

extension Store {
    /// A use stamp is rewritten at most this often, so hot paths don't write on every call.
    private static let stampResolution: TimeInterval = 60 * 60
    /// Scratch older than this belongs to a run that is no longer going.
    private static let staleScratchAge: TimeInterval = 24 * 60 * 60
    private static let archiveSuffix = ".zip"
    private static let jsonSuffix = ".json"
    /// `tools/index/` maps exact versions to builds; it is cleaned with the builds it points to.
    private static let toolIndexDirectory = "index"

    // MARK: Recording use

    /// Notes that the store entry holding `url` was just used. Entries are the first level of a
    /// section (`trees/<revision>`); the stamp lives apart, so the entry's own mtimes never change.
    public func markUsed(_ url: URL) {
        guard let (directory, name) = self.entry(containing: url) else { return }
        let stamp = self.stampPath(directory, name)
        if let date = FileSystem.modificationDate(of: stamp), Date().timeIntervalSince(date) < Self.stampResolution {
            return
        }
        try? FileSystem.touch(stamp)
    }

    /// Records what a project pins, rewriting the record only when it changed.
    public func recordProject(_ project: StoreProject) throws {
        let path = self.projectPath(resolvedFile: project.resolvedFile)
        if let data = FileSystem.readIfPresent(path), (try? JSONDecoder().decode(StoreProject.self, from: data)) == project {
            return
        }
        try FileSystem.writeAtomically(try JSONEncoder().encode(project), to: path)
    }

    private func projectPath(resolvedFile: String) -> URL {
        self.directory(.projects).appendingPathComponent(ContentHash.sha256(resolvedFile) + Self.jsonSuffix)
    }

    /// The section and name of the entry `url` is in, when it is in one.
    private func entry(containing url: URL) -> (Directory, String)? {
        let rootComponents = self.root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count > rootComponents.count + 1, Array(components.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }
        guard let directory = Directory(rawValue: components[rootComponents.count]) else { return nil }
        return (directory, components[rootComponents.count + 1])
    }

    private func stampPath(_ directory: Directory, _ name: String) -> URL {
        self.directory(.uses).appendingPathComponent(directory.rawValue, isDirectory: true).appendingPathComponent(name)
    }

    // MARK: Size

    /// The size of every section, largest first.
    public func sizes() -> [StoreSectionSize] {
        StoreSection.allCases.map { section in
            let directory = self.directory(section.directory)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return StoreSectionSize(section: section, entries: names.count, bytes: FileSystem.size(of: directory))
        }
        .sorted { $0.bytes > $1.bytes }
    }

    // MARK: Prune

    /// Removes entries that no live project pins and that weren't used within `age`, plus stale
    /// scratch. Projects keep working: their checkouts are copies, so only a fresh checkout of a
    /// removed entry fetches it again.
    public func prune(unusedFor age: TimeInterval, effect: PruneEffect, now: Date = Date()) throws -> StorePruneReport {
        var report = StorePruneReport()

        // What live projects pin is kept regardless of age.
        let projects = self.liveProjects(effect: effect, report: &report)
        let keptTrees = Set(projects.flatMap(\.revisions))
        let keptRepositories = Set(projects.flatMap(\.repositories).map { self.repositoryPath(for: $0, name: "").lastPathComponent })

        for section in StoreSection.allCases {
            switch section.pruning {
            case .never:
                continue
            case .whenStale:
                try self.pruneStale(section, olderThan: Self.staleScratchAge, now: now, effect: effect, into: &report)
            case .whenUnused:
                try self.pruneUnused(section, unusedFor: age, now: now, effect: effect, into: &report) { name in
                    switch section {
                    case .sourceTrees:
                        return keptTrees.contains(name)
                    case .repositories:
                        // Named `<name>-<hash of URL>`; the hash alone identifies the repository.
                        return keptRepositories.contains { name.hasSuffix($0) }
                    default:
                        return false
                    }
                }
            }
        }

        // Exact-version tool lookups whose build is gone would only miss.
        if effect == .apply {
            self.removeDanglingToolIndexes()
        }
        return report
    }

    /// Project records whose `Package.resolved` still exists; the others are dropped.
    private func liveProjects(effect: PruneEffect, report: inout StorePruneReport) -> [StoreProject] {
        let directory = self.directory(.projects)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var live: [StoreProject] = []
        for name in names {
            let path = directory.appendingPathComponent(name)
            if let data = FileSystem.readIfPresent(path),
               let project = try? JSONDecoder().decode(StoreProject.self, from: data),
               FileSystem.exists(URL(fileURLWithPath: project.resolvedFile)) {
                live.append(project)
                continue
            }
            report.forgottenProjects += 1
            if effect == .apply {
                try? FileSystem.removeTree(path)
            }
        }
        return live
    }

    private func pruneUnused(
        _ section: StoreSection,
        unusedFor age: TimeInterval,
        now: Date,
        effect: PruneEffect,
        into report: inout StorePruneReport,
        isPinned: (String) -> Bool
    ) throws {
        let directory = self.directory(section.directory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []

        for name in names.sorted() {
            // A registry release is its tree plus its archive, used and removed together.
            if section == .registry, name.hasSuffix(Self.archiveSuffix) {
                continue
            }
            if section == .tools, name == Self.toolIndexDirectory {
                continue
            }
            if isPinned(name) {
                continue
            }

            // Last use: the stamp, or the entry itself for entries made before stamps existed.
            let entry = directory.appendingPathComponent(name)
            let stamp = self.stampPath(section.directory, name)
            let lastUse = [FileSystem.modificationDate(of: stamp), FileSystem.modificationDate(of: entry)].compactMap { $0 }.max() ?? .distantPast
            guard now.timeIntervalSince(lastUse) >= age else { continue }

            var parts = [entry]
            if section == .registry {
                parts.append(directory.appendingPathComponent(name + Self.archiveSuffix))
            }
            report.add(section, bytes: parts.reduce(0) { $0 + FileSystem.size(of: $1) })
            guard effect == .apply else { continue }
            for part in parts {
                try FileSystem.removeTree(part)
            }
            try? FileSystem.removeTree(stamp)
        }
    }

    private func pruneStale(_ section: StoreSection, olderThan age: TimeInterval, now: Date, effect: PruneEffect, into report: inout StorePruneReport) throws {
        let directory = self.directory(section.directory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names {
            let entry = directory.appendingPathComponent(name)
            guard let modified = FileSystem.modificationDate(of: entry), now.timeIntervalSince(modified) >= age else { continue }
            report.add(section, bytes: FileSystem.size(of: entry))
            if effect == .apply {
                try FileSystem.removeTree(entry)
            }
        }
    }

    /// Each index file holds the path of a build's metadata.
    private func removeDanglingToolIndexes() {
        let directory = self.directory(.tools).appendingPathComponent(Self.toolIndexDirectory, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names {
            let index = directory.appendingPathComponent(name)
            guard let target = FileSystem.readIfPresent(index).map({ String(decoding: $0, as: UTF8.self) }),
                  !FileSystem.exists(URL(fileURLWithPath: target)) else { continue }
            try? FileSystem.removeTree(index)
        }
    }
}
