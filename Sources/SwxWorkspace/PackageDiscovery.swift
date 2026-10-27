import Foundation
import SwxCore
import SwxSystem

/// The packages of a repository, for `--all`: every directory below the root with a
/// `Package.swift`, nested ones included (a monorepo's root package and its local packages).
public enum PackageDiscovery {
    /// Never searched: build output (whose checkouts hold manifests too), editor and tool
    /// state, and other ecosystems' dependency folders.
    private static let skippedDirectories: Set<String> = [WellKnownFile.buildDirectory, "DerivedData", "node_modules", "Carthage", "Pods"]
    private static let hiddenPrefix = "."
    /// Where `swift package edit` puts the packages it hands to the user.
    private static let editedPackagesDirectory = "Packages"
    private static let editedState = "\"edited\""

    /// Package directories under `root`, sorted by path; `root` itself first when it is one.
    /// Paths stay spelled as given (Foundation's `standardizedFileURL` would drop `/private`,
    /// and SwiftPM's files record paths as the user spelled them).
    public static func packages(under root: URL) -> [URL] {
        var found: [URL] = []
        Self.search(URL(fileURLWithPath: FileSystem.normalize(root.path, relativeTo: FileManager.default.currentDirectoryPath), isDirectory: true), into: &found)
        return found.sorted { $0.path < $1.path }
    }

    private static func search(_ directory: URL, into found: inout [URL]) {
        let isPackage = FileSystem.exists(directory.appendingPathComponent(WellKnownFile.manifest))
        if isPackage {
            found.append(directory)
        }

        // A package with edited dependencies keeps them in Packages/: they belong to it.
        let skipsEdited = isPackage && Self.hasEditedDependencies(directory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where !name.hasPrefix(Self.hiddenPrefix) && !Self.skippedDirectories.contains(name) {
            if skipsEdited, name == Self.editedPackagesDirectory {
                continue
            }
            let child = directory.appendingPathComponent(name, isDirectory: true)
            // Real directories only: a symlink could lead back up the tree.
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true else {
                continue
            }
            Self.search(child, into: &found)
        }
    }

    private static func hasEditedDependencies(_ package: URL) -> Bool {
        let state = package.appendingPathComponent(WellKnownFile.buildDirectory).appendingPathComponent(WellKnownFile.workspaceState)
        guard let data = FileSystem.readIfPresent(state) else { return false }
        return String(decoding: data, as: UTF8.self).contains(Self.editedState)
    }

    /// `path` relative to `root`, for messages (`.` for the root itself).
    public static func relativePath(of path: URL, to root: URL) -> String {
        let base = FileSystem.normalize(root.path, relativeTo: FileManager.default.currentDirectoryPath)
        let full = FileSystem.normalize(path.path, relativeTo: FileManager.default.currentDirectoryPath)
        guard full != base else { return "." }
        guard full.hasPrefix(base + "/") else { return full }
        return String(full.dropFirst(base.count + 1))
    }
}
