import Foundation
import SwxSystem

/// Remembers `xcodebuild -list` (about 2.5 s per call) between builds, keyed by the files that
/// decide the schemes and by the selected Xcode. Like make, it compares sizes and modification
/// times: any edit, checkout or Xcode switch lists again.
struct SchemeListCache {
    private enum Layout {
        static let file = "swx-schemes.json"
        static let packageManifestPrefix = "Package"
        static let swiftExtension = "swift"
        static let resolvedFile = "Package.resolved"
        static let packageXcodeDirectory = ".swiftpm/xcode"
        static let sharedData = "xcshareddata"
        static let userData = "xcuserdata"
        static let projectFile = "project.pbxproj"
        static let developerDirectoryVariable = "DEVELOPER_DIR"
        static let xcodeInfo = "../Info.plist"
    }

    private struct Entry: Codable {
        let fingerprint: String
        let schemes: [String]
    }

    private let file: URL

    init(derivedData: URL) {
        self.file = derivedData.appendingPathComponent(Layout.file)
    }

    /// The remembered schemes, if nothing they depend on changed.
    func schemes(directory: URL, container: URL?) async -> [String]? {
        guard let fingerprint = await Self.fingerprint(directory: directory, container: container),
              let data = FileSystem.readIfPresent(self.file),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.fingerprint == fingerprint else {
            return nil
        }
        return entry.schemes
    }

    func remember(_ schemes: [String], directory: URL, container: URL?) async {
        guard let fingerprint = await Self.fingerprint(directory: directory, container: container),
              let data = try? JSONEncoder().encode(Entry(fingerprint: fingerprint, schemes: schemes)) else {
            return
        }
        try? FileSystem.createDirectory(self.file.deletingLastPathComponent())
        try? FileSystem.writeAtomically(data, to: self.file)
    }

    // MARK: Fingerprint

    /// The selected Xcode and every input of the scheme list; `nil` when it can't be told
    /// (a workspace, whose projects live anywhere): those are always listed.
    private static func fingerprint(directory: URL, container: URL?) async -> String? {
        guard let developer = await Self.developerDirectory() else { return nil }
        var inputs = [developer, developer.appendingPathComponent(Layout.xcodeInfo).standardizedFileURL]

        switch container?.pathExtension {
        case nil:
            // A package: its manifests, pins and the schemes saved next to it.
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            inputs += names.sorted()
                .filter { $0.hasPrefix(Layout.packageManifestPrefix) && $0.hasSuffix("." + Layout.swiftExtension) }
                .map { directory.appendingPathComponent($0) }
            inputs.append(directory.appendingPathComponent(Layout.resolvedFile))
            inputs += Self.schemeFiles(in: directory.appendingPathComponent(Layout.packageXcodeDirectory))
        case XcodeProjectKind.project.rawValue?:
            guard let container else { return nil }
            inputs.append(container.appendingPathComponent(Layout.projectFile))
            inputs += Self.schemeFiles(in: container)
        default:
            return nil
        }
        return inputs.map(Self.stamp).joined(separator: "\n")
    }

    /// Shared and per-user scheme files under an Xcode directory.
    private static func schemeFiles(in directory: URL) -> [URL] {
        [Layout.sharedData, Layout.userData].flatMap { name -> [URL] in
            let root = directory.appendingPathComponent(name)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
            return walker.compactMap { $0 as? URL }.sorted { $0.path < $1.path }
        }
    }

    /// Path, size and modification time of the item itself (a directory isn't walked); a
    /// missing file still counts, since it may appear later.
    private static func stamp(_ url: URL) -> String {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.path) \(size) \(modified)"
    }

    /// `DEVELOPER_DIR`, else the Xcode `xcode-select` reports (its default when none was chosen).
    private static func developerDirectory() async -> URL? {
        if let path = ProcessInfo.processInfo.environment[Layout.developerDirectoryVariable] {
            return URL(fileURLWithPath: path)
        }
        guard let result = try? await ProcessRunner.run(["xcode-select", "-p"]) else { return nil }
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    private enum XcodeProjectKind: String {
        case project = "xcodeproj"
    }
}
