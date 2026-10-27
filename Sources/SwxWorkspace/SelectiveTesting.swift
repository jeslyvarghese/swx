import Foundation
import SwxCore
import SwxGraph
import SwxManifest
import SwxStore
import SwxSystem

/// `swx test --selective`: which test targets must run, and which passed with exactly these inputs before.
public struct SelectiveTestPlan: Sendable {
    /// Test targets whose inputs changed since they last passed (or never passed).
    public let run: [String]
    /// Test targets that passed with exactly these inputs.
    public let skipped: [String]
    /// Every test target's key: its inputs, hashed.
    public let keys: [String: String]

    /// `swift test --filter` for the targets to run; `nil` when every target runs.
    public var filter: String? {
        guard !self.skipped.isEmpty, !self.run.isEmpty else { return nil }
        let modules = self.run.map(PackageGraph.moduleName(of:)).sorted()
        return "^(" + modules.joined(separator: "|") + ")\\."
    }
}

extension Workspace {
    private enum Selective {
        /// Bumped whenever what goes into a key changes, so old results stop matching.
        static let formatVersion = "swx-selective-1"
        /// Never part of a package's inputs.
        static let ignoredDirectories: Set<String> = [WellKnownFile.buildDirectory, ".swiftpm", ".git"]
        static let separator = "\u{0}"
    }

    /// Splits the root's test targets into those to run and those that already passed with these
    /// inputs: their sources and the sources of everything they depend on in the package, the
    /// manifest, the pins, path dependencies, the toolchain and the `swift test` arguments.
    public func selectiveTestPlan(arguments: [String]) async throws -> SelectiveTestPlan {
        let keys = try await self.testTargetKeys(arguments: arguments)
        var run: [String] = []
        var skipped: [String] = []
        for (target, key) in keys.sorted(by: { $0.key < $1.key }) {
            if FileSystem.exists(self.store.testResultPath(key: key)) {
                self.store.markUsed(self.store.testResultPath(key: key))
                skipped.append(target)
            } else {
                run.append(target)
            }
        }
        return SelectiveTestPlan(run: run, skipped: skipped, keys: keys)
    }

    /// Remembers that the plan's targets to run passed.
    public func recordPassed(_ plan: SelectiveTestPlan) throws {
        for target in plan.run {
            guard let key = plan.keys[target] else { continue }
            try FileSystem.writeAtomically(Data(), to: self.store.testResultPath(key: key))
        }
    }

    /// Each test target's key: a hash of everything its result depends on.
    func testTargetKeys(arguments: [String]) async throws -> [String: String] {
        guard case .package(let directory) = self.options.root else {
            throw WorkspaceError(description: "selective testing works on packages")
        }
        let toolchain = try await Toolchain.detect(store: self.store)
        let loader = ManifestLoader(store: self.store, toolchain: toolchain, maximumConcurrency: self.options.maximumConcurrency)
        let manifest = try await loader.load(packageAt: directory)

        // Inputs every target shares.
        let root = try await self.rootContext()
        let state = FileSystem.readIfPresent(root.layout.workspaceState).flatMap(WorkspaceState.decodeIfCompatible) ?? WorkspaceState(dependencies: [:])
        let pathDependencies = state.dependencies.values.compactMap { dependency -> String? in
            guard case .fileSystem(let path) = dependency.state else { return nil }
            return Self.contentHash(of: URL(fileURLWithPath: path, isDirectory: true))
        }.sorted()
        let shared = [
            Selective.formatVersion,
            toolchain.key,
            Self.fileHash(directory.appendingPathComponent(WellKnownFile.manifest)),
            Self.fileHash(root.layout.resolvedFile),
            pathDependencies.joined(separator: Selective.separator),
            arguments.joined(separator: Selective.separator),
        ].joined(separator: Selective.separator)

        // Targets hash their own files and, recursively, their in-package dependencies.
        let targets = Dictionary(manifest.targets.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var memo: [String: String] = [:]
        func targetHash(_ name: String, visiting: Set<String>) -> String {
            if let known = memo[name] {
                return known
            }
            guard let target = targets[name], !visiting.contains(name) else { return "" }
            let files = Self.sourceDirectory(of: target, in: directory).map(Self.contentHash(of:)) ?? ""
            let dependencies = Self.localDependencies(of: target, in: targets).map { targetHash($0, visiting: visiting.union([name])) }
            let hash = ContentHash.sha256(([name, files] + dependencies.sorted()).joined(separator: Selective.separator))
            memo[name] = hash
            return hash
        }

        var keys: [String: String] = [:]
        for target in manifest.targets where target.kind == .test {
            keys[target.name] = ContentHash.sha256(shared + Selective.separator + targetHash(target.name, visiting: []))
        }
        return keys
    }

    /// Targets of the same package a target uses: by `.target`, `.byName`, or as a plugin.
    private static func localDependencies(of target: Manifest.Target, in targets: [String: Manifest.Target]) -> [String] {
        let referenced = target.dependencies.compactMap { dependency -> String? in
            switch dependency {
            case .target(let name, _), .byName(let name, _):
                return targets[name] == nil ? nil : name
            case .product:
                return nil
            }
        }
        let plugins = target.pluginUsages.filter { $0.package == nil && targets[$0.name] != nil }.map(\.name)
        return referenced + plugins
    }

    // MARK: Hashing

    private static func fileHash(_ url: URL) -> String {
        (try? ContentHash.sha256(fileAt: url)) ?? ""
    }

    /// Every file below `directory` (build and VCS directories aside), by relative path and content.
    static func contentHash(of directory: URL) -> String {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return "" }
        var entries: [String] = []
        let base = directory.standardizedFileURL.path
        for case let url as URL in enumerator {
            if Selective.ignoredDirectories.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count))
            entries.append(relative + Selective.separator + Self.fileHash(url))
        }
        return ContentHash.sha256(entries.sorted().joined(separator: "\n"))
    }
}
