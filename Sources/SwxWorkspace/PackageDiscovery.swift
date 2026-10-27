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

    /// `.swx/workspace.json` at the root: which packages `--all` covers.
    private struct Configuration: Decodable {
        /// Globs of package directories; absent, every package found.
        var packages: [String]?
        /// Globs of package directories to leave out.
        var exclude: [String]?
    }

    private static let configurationPath = ".swx/workspace.json"

    /// Package directories under `root`, sorted by path; `root` itself first when it is one.
    /// `.swx/workspace.json` narrows them: `packages` globs say which to cover, `exclude` globs
    /// which to leave out (`*` within a path component, `**` across them). Paths stay spelled
    /// as given (Foundation's `standardizedFileURL` would drop `/private`, and SwiftPM's files
    /// record paths as the user spelled them).
    public static func packages(under root: URL) throws -> [URL] {
        let base = URL(fileURLWithPath: FileSystem.normalize(root.path, relativeTo: FileManager.default.currentDirectoryPath), isDirectory: true)
        var found: [URL] = []
        Self.search(base, into: &found)

        // The configuration, when there is one, narrows what was found.
        let file = base.appendingPathComponent(Self.configurationPath)
        if let data = FileSystem.readIfPresent(file) {
            let configuration: Configuration
            do {
                configuration = try JSONDecoder().decode(Configuration.self, from: data)
            } catch {
                throw WorkspaceError(description: "\(Self.configurationPath): \(error)")
            }
            found = found.filter { package in
                let path = Self.relativePath(of: package, to: base)
                let included = configuration.packages.map { $0.contains { Glob.matches($0, path) } } ?? true
                let excluded = (configuration.exclude ?? []).contains { Glob.matches($0, path) }
                return included && !excluded
            }
        }
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

/// Path globs for `.swx/workspace.json`: `*` matches within a path component, `**` any number
/// of components (none included), anything else itself; `.` is the root.
enum Glob {
    private static let separator: Character = "/"
    private static let anyComponents = "**"
    private static let anyCharacters: Character = "*"

    static func matches(_ pattern: String, _ path: String) -> Bool {
        let patternParts = pattern.split(separator: Self.separator).map(String.init)
        let pathParts = path.split(separator: Self.separator).map(String.init)
        return Self.match(patternParts[...], pathParts[...])
    }

    private static func match(_ pattern: ArraySlice<String>, _ path: ArraySlice<String>) -> Bool {
        guard let first = pattern.first else { return path.isEmpty }
        if first == Self.anyComponents {
            // Zero components, or one more.
            return Self.match(pattern.dropFirst(), path) || (!path.isEmpty && Self.match(pattern, path.dropFirst()))
        }
        guard let component = path.first, Self.matchComponent(Array(first), Array(component)) else { return false }
        return Self.match(pattern.dropFirst(), path.dropFirst())
    }

    /// One component, `*` standing for any run of characters.
    private static func matchComponent(_ pattern: [Character], _ text: [Character]) -> Bool {
        guard let first = pattern.first else { return text.isEmpty }
        if first == Self.anyCharacters {
            return (0...text.count).contains { Self.matchComponent(Array(pattern.dropFirst()), Array(text.dropFirst($0))) }
        }
        guard let character = text.first, character == first else { return false }
        return Self.matchComponent(Array(pattern.dropFirst()), Array(text.dropFirst()))
    }
}
