import Foundation
import SwxCore
import SwxStore
import SwxSystem

/// Which release `swx self update` installs.
public enum ReleaseChoice: Sendable, Equatable {
    case latest
    /// A tag such as `v0.4.0` (a bare `0.4.0` is read the same way).
    case tag(String)
}

/// Whether `swx self update` replaces the binary, or only says what it would install.
public enum UpdateEffect: Sendable {
    case install
    case check
}

/// What `swx self update` did.
public enum SelfUpdateOutcome: Sendable, Equatable {
    case upToDate(version: String)
    case available(version: String)
    case installed(from: String, to: String, at: URL)
}

public struct SelfUpdateError: Error, CustomStringConvertible, Sendable {
    public let description: String
}

/// Replaces the running swx with a published release, checked against the release's
/// `SHA256SUMS`, as `Scripts/install.sh` installs it.
public struct SelfUpdate: Sendable {
    private enum Release {
        static let repository = "jeslyvarghese/swx"
        static let checksums = "SHA256SUMS"
        static let tagPrefix = "v"
        static let latestAPI = "https://api.github.com/repos/\(Self.repository)/releases/latest"
        static let downloads = "https://github.com/\(Self.repository)/releases/download"
        static let acceptHeader = ["Accept": "application/vnd.github+json"]
    }

    private enum Environment {
        /// Same variable as the install script: a mirror of the release assets.
        static let downloadURL = "SWX_DOWNLOAD_URL"
    }

    /// Package managers that own their installs; overwriting theirs would confuse them.
    private static let managedInstalls: [(marker: String, command: String)] = [
        ("/Cellar/", "brew upgrade swx"),
        ("/.mint/", "mint install jeslyvarghese/swx"),
    ]

    private static let executableName = "swx"
    private static let versionFlag = "--version"
    private static let tarExecutable = "tar"
    private static let extractArguments = ["-xzf"]
    private static let directoryFlag = "-C"
    private static let stagingPrefix = ".swx-update-"
    private static let executablePermissions = 0o755

    let currentVersion: String
    let executable: URL
    let environment: [String: String]

    /// `executable` defaults to the running binary, through any `swift-x` symlink.
    public init(currentVersion: String, executable: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.currentVersion = currentVersion
        self.executable = (executable ?? Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        self.environment = environment
    }

    /// The release asset for this machine, named as the release workflow names it.
    static var assetName: String {
        #if os(macOS)
        return "swx-macos-universal.tar.gz"
        #elseif arch(x86_64)
        return "swx-linux-x86_64.tar.gz"
        #else
        return "swx-linux-aarch64.tar.gz"
        #endif
    }

    public func run(_ choice: ReleaseChoice, effect: UpdateEffect) async throws -> SelfUpdateOutcome {
        if let managed = Self.managedInstalls.first(where: { self.executable.path.contains($0.marker) }) {
            throw SelfUpdateError(description: "\(self.executable.path) is managed by a package manager; run `\(managed.command)`")
        }

        // Which version, and where its assets are.
        let tag = try await self.tag(for: choice)
        let version = Self.version(fromTag: tag)
        guard version != self.currentVersion || choice != .latest else {
            return .upToDate(version: version)
        }
        guard effect == .install else {
            return .available(version: version)
        }
        guard let base = self.environment[Environment.downloadURL].flatMap(URL.init(string:))
                ?? URL(string: Release.downloads)?.appendingPathComponent(tag) else {
            throw SelfUpdateError(description: "$\(Environment.downloadURL) is not a URL")
        }

        // Stage beside the binary, so the final rename stays on one volume.
        let directory = self.executable.deletingLastPathComponent()
        let staging = directory.appendingPathComponent(Self.stagingPrefix + UUID().uuidString, isDirectory: true)
        do {
            try FileSystem.createDirectory(staging)
        } catch {
            throw SelfUpdateError(description: "can't write to \(directory.path) (\(error.localizedDescription)); reinstall with the install script or with sudo")
        }
        defer { try? FileSystem.removeTree(staging) }

        // Download and check the archive against the published checksum.
        let archive = staging.appendingPathComponent(Self.assetName)
        let checksums = staging.appendingPathComponent(Release.checksums)
        try await HTTP.download(base.appendingPathComponent(Self.assetName), to: archive)
        try await HTTP.download(base.appendingPathComponent(Release.checksums), to: checksums)
        guard let expected = Self.checksum(of: Self.assetName, in: String(decoding: try FileSystem.read(checksums), as: UTF8.self)) else {
            throw SelfUpdateError(description: "\(Self.assetName) is not listed in \(Release.checksums) of \(tag)")
        }
        let actual = try ContentHash.sha256(fileAt: archive)
        guard actual == expected else {
            throw SelfUpdateError(description: "checksum mismatch for \(Self.assetName): expected \(expected), got \(actual)")
        }

        // The new binary must run and report the version asked for before it replaces this one.
        try await ProcessRunner.run([Self.tarExecutable] + Self.extractArguments + [archive.path, Self.directoryFlag, staging.path])
        let binary = staging.appendingPathComponent(Self.executableName)
        try FileManager.default.setAttributes([.posixPermissions: Self.executablePermissions], ofItemAtPath: binary.path)
        let reported = try await ProcessRunner.run([binary.path, Self.versionFlag]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reported == version else {
            throw SelfUpdateError(description: "the downloaded swx reports version \(reported), expected \(version)")
        }

        try FileSystem.replace(self.executable, with: binary)
        return .installed(from: self.currentVersion, to: version, at: self.executable)
    }

    /// The release tag: given, or the latest release's (GitHub's API; a mirror needs a tag).
    private func tag(for choice: ReleaseChoice) async throws -> String {
        switch choice {
        case .tag(let tag):
            return tag.hasPrefix(Release.tagPrefix) ? tag : Release.tagPrefix + tag
        case .latest:
            guard self.environment[Environment.downloadURL] == nil else {
                throw SelfUpdateError(description: "with $\(Environment.downloadURL), name the release: swx self update --version <tag>")
            }
            guard let api = URL(string: Release.latestAPI) else {
                throw SelfUpdateError(description: "invalid release API URL \(Release.latestAPI)")
            }
            let response = try await HTTP.get(api, headers: Release.acceptHeader)
            guard let release = try? JSONDecoder().decode(LatestRelease.self, from: response.body) else {
                throw SelfUpdateError(description: "could not read the latest release from \(Release.latestAPI) (HTTP \(response.status))")
            }
            return release.tagName
        }
    }

    private struct LatestRelease: Decodable {
        let tagName: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
        }
    }

    static func version(fromTag tag: String) -> String {
        tag.hasPrefix(Release.tagPrefix) ? String(tag.dropFirst(Release.tagPrefix.count)) : tag
    }

    /// The checksum `sha256sum` printed for `name`: lines of `<hex>  <name>`.
    static func checksum(of name: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[1] == name else { continue }
            return String(fields[0])
        }
        return nil
    }
}
