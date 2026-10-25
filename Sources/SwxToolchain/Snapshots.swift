import Foundation
import SwxSystem

/// A development snapshot request: `main-snapshot`, `6.5-snapshot`, a dated form
/// (`main-snapshot-2026-10-17`), or an exact tag (`swift-DEVELOPMENT-SNAPSHOT-2026-10-17-a`,
/// `swift-6.5-DEVELOPMENT-SNAPSHOT-2026-10-17-a`), as swiftly spells them.
public struct SnapshotRequest: Sendable, Hashable {
    /// `main`, or a release branch such as `6.5`.
    public let branch: String
    /// `2026-10-17`, or `nil` for the newest.
    public let date: String?
    /// The full tag when one was given.
    public let tag: String?

    static let mainBranch = "main"
    private static let requestSuffix = "-snapshot"
    private static let tagPrefix = "swift-"
    private static let tagMarker = "DEVELOPMENT-SNAPSHOT-"
    private static let dateLength = 10

    public init?(_ request: String) {
        let request = request.trimmingCharacters(in: .whitespacesAndNewlines)

        // An exact tag names its branch: `swift-6.5-DEVELOPMENT-…` or `swift-DEVELOPMENT-…` (main).
        if request.hasPrefix(Self.tagPrefix), let marker = request.range(of: Self.tagMarker) {
            let between = request[request.index(request.startIndex, offsetBy: Self.tagPrefix.count)..<marker.lowerBound]
            self.branch = between.isEmpty ? Self.mainBranch : String(between.dropLast())
            self.date = String(request[marker.upperBound...].prefix(Self.dateLength))
            self.tag = request
            return
        }

        // `<branch>-snapshot[-YYYY-MM-DD]`.
        guard let suffix = request.range(of: Self.requestSuffix) else { return nil }
        let branch = String(request[..<suffix.lowerBound])
        let rest = request[suffix.upperBound...]
        guard !branch.isEmpty, rest.isEmpty || rest.hasPrefix("-") else { return nil }
        self.branch = branch
        self.date = rest.isEmpty ? nil : String(rest.dropFirst())
        self.tag = nil
    }

    /// Installed snapshot directories are named by tag; this is the tag prefix for the branch.
    var tagPrefix: String {
        self.branch == Self.mainBranch
            ? Self.tagPrefix + Self.tagMarker
            : Self.tagPrefix + self.branch + "-" + Self.tagMarker
    }

    /// Does an installed toolchain named `name` satisfy this request?
    func matches(installedName name: String) -> Bool {
        if let tag = self.tag {
            return name == tag
        }
        guard name.hasPrefix(self.tagPrefix) else { return false }
        guard let date = self.date else { return true }
        return name.dropFirst(self.tagPrefix.count).hasPrefix(date)
    }
}

/// One published snapshot.
struct Snapshot: Sendable, Hashable {
    let tag: String
    let download: URL
}

/// swift.org's snapshot catalog (`/api/v1/install/dev/<branch>/<platform>.json`).
enum SnapshotCatalog {
    private enum Remote {
        static let catalog = "https://www.swift.org/api/v1/install/dev"
        static let downloads = "https://download.swift.org"
        static let mainDirectory = "development"
        static let branchDirectorySuffix = "-branch"
        static let branchDirectoryPrefix = "swift-"
        static let jsonExtension = ".json"
    }

    private enum Platform {
        static let macOSCatalog = "macos"
        static let macOSDirectory = "xcode"
        static let macOSArchitecture = "universal"
        static let armArchitecture = "aarch64"
        static let intelArchitecture = "x86_64"
        static let armSuffix = "-aarch64"
    }

    private struct Entry: Decodable {
        let dir: String
        let download: String
    }

    /// The newest snapshot matching `request`, newest first in the catalog.
    static func find(_ request: SnapshotRequest) async throws -> Snapshot {
        let (catalogName, architecture, platformDirectory) = try Self.platform()
        guard let url = URL(string: "\(Remote.catalog)/\(request.branch)/\(catalogName)\(Remote.jsonExtension)") else {
            throw ToolchainError(description: "invalid snapshot branch '\(request.branch)'")
        }

        let response = try await HTTP.get(url, headers: [:])
        guard response.status == 200 else {
            throw ToolchainError(description: "swift.org publishes no snapshots for '\(request.branch)' (HTTP \(response.status))")
        }
        let catalog = try JSONDecoder().decode([String: [Entry]].self, from: response.body)
        let entries = catalog[architecture] ?? []

        guard let entry = entries.first(where: { request.matches(installedName: $0.dir) }) else {
            throw ToolchainError(description: "no \(request.branch) snapshot matches '\(request.tag ?? request.date ?? "latest")'")
        }

        // Snapshots of main live under `development/`, branch snapshots under `swift-X.Y-branch/`.
        let branchDirectory = request.branch == SnapshotRequest.mainBranch
            ? Remote.mainDirectory
            : Remote.branchDirectoryPrefix + request.branch + Remote.branchDirectorySuffix
        guard let download = URL(string: "\(Remote.downloads)/\(branchDirectory)/\(platformDirectory)/\(entry.dir)/\(entry.download)") else {
            throw ToolchainError(description: "invalid snapshot download for \(entry.dir)")
        }
        return Snapshot(tag: entry.dir, download: download)
    }

    /// `(catalog name, architecture key, download directory)` for this machine.
    private static func platform() throws -> (String, String, String) {
        #if os(macOS)
        return (Platform.macOSCatalog, Platform.macOSArchitecture, Platform.macOSDirectory)
        #elseif os(Linux)
        let platform = try LinuxPlatform.current()
        let architecture = platform.isArm ? Platform.armArchitecture : Platform.intelArchitecture
        return (platform.directory, architecture, platform.directory + (platform.isArm ? Platform.armSuffix : ""))
        #else
        throw ToolchainError(description: "snapshots are not available for this platform")
        #endif
    }
}
