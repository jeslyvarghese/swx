import Foundation
import SwxSystem

/// Unzipping downloaded archives (binary targets, registry releases) the way SwiftPM does.
enum ArchiveExtraction {
    /// SwiftPM extracts with `unzip` too, so archives behave the same.
    private enum Unzip {
        static let executable = "unzip"
        static let quiet = "-q"
        static let destination = "-d"
    }

    private static let pathSeparator = "/"

    /// Extracts `archive` into `directory`, refusing links that point outside it.
    static func unzip(_ archive: URL, into directory: URL) async throws {
        try FileSystem.createDirectory(directory)
        try await ProcessRunner.run([Unzip.executable, Unzip.quiet, archive.path, Unzip.destination, directory.path])
        try Self.validateNoEscapingSymlinks(in: directory)
    }

    /// An archive must not plant links that reach outside itself.
    static func validateNoEscapingSymlinks(in root: URL) throws {
        let rootPath = root.path
        guard let enumerator = FileManager.default.enumerator(atPath: rootPath) else { return }

        for case let relative as String in enumerator {
            let path = rootPath + Self.pathSeparator + relative
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { continue }

            let parent = (path as NSString).deletingLastPathComponent
            let resolved = FileSystem.normalize(target, relativeTo: parent)
            guard !target.hasPrefix(Self.pathSeparator), resolved.hasPrefix(rootPath + Self.pathSeparator) else {
                throw SourceError(description: "archive contains a link that escapes it: \(relative) -> \(target)")
            }
        }
    }

    /// SwiftPM's `stripFirstLevel`: registry archives wrap the package in one top-level directory.
    static func singleTopLevelDirectory(of root: URL) throws -> URL {
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        guard entries.count == 1, let only = entries.first else {
            throw SourceError(description: "expected one top-level directory in the archive, found \(entries.count) entries")
        }
        let wrapper = root.appendingPathComponent(only, isDirectory: true)
        guard FileSystem.isDirectory(wrapper) else {
            throw SourceError(description: "the archive's only entry '\(only)' is not a directory")
        }
        return wrapper
    }
}
