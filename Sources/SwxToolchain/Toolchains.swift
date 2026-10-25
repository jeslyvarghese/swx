import Foundation
import SwxSystem

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

/// A Swift release published on swift.org.
public struct ToolchainRelease: Sendable, Hashable, Decodable {
    /// `6.4.1`
    public let name: String
    /// `swift-6.4.1-RELEASE`
    public let tag: String
}

/// An installed toolchain.
public struct InstalledToolchain: Sendable, Hashable {
    public let name: String
    public let root: URL

    public var binDirectory: URL {
        self.root.appendingPathComponent(ToolchainManager.Path.binary, isDirectory: true)
    }
}

public struct ToolchainError: Error, CustomStringConvertible {
    public let description: String

    public init(description: String) {
        self.description = description
    }
}

/// Installs, lists and selects Swift toolchains (the `swiftly` part of swx).
///
/// Toolchains live under `$SWX_HOME/toolchains` (default `~/.local/share/swx/toolchains`),
/// one directory per release name, each containing `usr/bin/swift`.
public struct ToolchainManager: Sendable {
    enum Path {
        static let binary = "usr/bin"
        static let toolchains = "toolchains"
        static let swiftVersionFile = ".swift-version"
        static let defaultData = ".local/share/swx"
    }

    private enum Environment {
        static let home = "SWX_HOME"
        static let path = "PATH"
        static let toolchains = "TOOLCHAINS"
    }

    private enum Remote {
        static let releases = URL(string: "https://www.swift.org/api/v1/install/releases.json")!
        static let downloads = "https://download.swift.org"
    }

    private enum Swift {
        static let versionPrefix = "Swift version "
        static let pathSeparator = ":"
    }

    public let root: URL

    public init(root: URL? = nil) {
        if let root {
            self.root = root
            return
        }
        let environment = ProcessInfo.processInfo.environment
        let data = environment[Environment.home].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(Path.defaultData)
        self.root = data.appendingPathComponent(Path.toolchains, isDirectory: true)
    }

    // MARK: Catalog

    /// All releases, oldest first.
    public func availableReleases() async throws -> [ToolchainRelease] {
        let data = try await HTTP.data(from: Remote.releases)
        return try JSONDecoder().decode([ToolchainRelease].self, from: data)
    }

    /// `6.3` → the newest `6.3.x`; `6.3.2` → exactly that; `latest` → the newest release.
    public static func match(_ request: String, in releases: [ToolchainRelease]) -> ToolchainRelease? {
        let request = request.trimmingCharacters(in: .whitespacesAndNewlines)
        if request == ToolchainRequest.latest {
            return releases.last
        }
        // `X.Y.Z` names one release; shorter requests take the newest release under them.
        let normalized = Self.dropTrailingZero(request)
        let isExact = request.split(separator: ".").count == Self.fullVersionComponents
        return releases.last { release in
            let name = Self.dropTrailingZero(release.name)
            return name == normalized || (!isExact && name.hasPrefix(normalized + ".")) || release.tag == request
        }
    }

    private static let fullVersionComponents = 3

    /// `6.0.0` and `6.0` name the same release on swift.org (`6.0`).
    private static func dropTrailingZero(_ version: String) -> String {
        var parts = version.split(separator: ".").map(String.init)
        while parts.count > 2, parts.last == "0" {
            parts.removeLast()
        }
        return parts.joined(separator: ".")
    }

    // MARK: Installed

    public func installed() -> [InstalledToolchain] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: self.root.path)) ?? []
        return names.sorted().compactMap { name in
            let toolchain = InstalledToolchain(name: name, root: self.root.appendingPathComponent(name, isDirectory: true))
            return FileSystem.exists(toolchain.binDirectory.appendingPathComponent("swift")) ? toolchain : nil
        }
    }

    public func installed(_ request: String) -> InstalledToolchain? {
        let installed = self.installed()

        // Snapshot directories are named by tag; the newest matching one wins (dates sort).
        if let snapshot = SnapshotRequest(request) {
            return installed.last { snapshot.matches(installedName: $0.name) }
        }
        let releases = installed.map { ToolchainRelease(name: $0.name, tag: "") }
        guard let match = Self.match(request, in: releases) else { return nil }
        return installed.first { $0.name == match.name }
    }

    public func uninstall(_ request: String) throws {
        guard let toolchain = self.installed(request) else {
            throw ToolchainError(description: "toolchain \(request) is not installed")
        }
        try FileSystem.removeTree(toolchain.root)
    }

    // MARK: Install

    /// Downloads and unpacks a release or development snapshot (no root privileges needed).
    public func install(_ request: String, progress: @Sendable (String) -> Void) async throws -> InstalledToolchain {
        if let snapshot = SnapshotRequest(request) {
            return try await self.installSnapshot(snapshot, progress: progress)
        }
        if let existing = self.installed(request) {
            return existing
        }
        guard let release = Self.match(request, in: try await self.availableReleases()) else {
            throw ToolchainError(description: "no Swift release matches '\(request)'")
        }
        return try await self.download(try Self.downloadURL(for: release), name: release.name, progress: progress)
    }

    /// An exact snapshot already installed needs no network; `main-snapshot` checks for a newer one.
    private func installSnapshot(_ request: SnapshotRequest, progress: @Sendable (String) -> Void) async throws -> InstalledToolchain {
        if request.tag != nil, let existing = self.installed().first(where: { request.matches(installedName: $0.name) }) {
            return existing
        }
        let snapshot = try await SnapshotCatalog.find(request)
        if let existing = self.installed().first(where: { $0.name == snapshot.tag }) {
            return existing
        }
        return try await self.download(snapshot.download, name: snapshot.tag, progress: progress)
    }

    private static let stagingPrefix = "swx-toolchain"

    private func download(_ url: URL, name: String, progress: @Sendable (String) -> Void) async throws -> InstalledToolchain {
        let staging = try FileSystem.makeTemporaryDirectory(prefix: Self.stagingPrefix)
        defer { try? FileSystem.removeTree(staging) }
        let destination = self.root.appendingPathComponent(name, isDirectory: true)

        progress("Downloading \(url.absoluteString)")
        let archive = staging.appendingPathComponent(url.lastPathComponent)
        try await HTTP.download(url, to: archive)

        progress("Unpacking \(name)")
        let unpacked = try await Self.unpack(archive, in: staging)
        try FileSystem.moveIntoPlace(unpacked, destination)
        return InstalledToolchain(name: name, root: destination)
    }

    /// The download for this machine.
    static func downloadURL(for release: ToolchainRelease) throws -> URL {
        // `swift-6.4.1-RELEASE` is published under `swift-6.4.1-release/`.
        let releaseDirectory = release.tag.lowercased()
        #if os(macOS)
        return URL(string: "\(Remote.downloads)/\(releaseDirectory)/xcode/\(release.tag)/\(release.tag)-osx.pkg")!
        #elseif os(Linux)
        let platform = try LinuxPlatform.current()
        let suffix = platform.isArm ? "-aarch64" : ""
        return URL(string: "\(Remote.downloads)/\(releaseDirectory)/\(platform.directory)\(suffix)/\(release.tag)/\(release.tag)-\(platform.fileComponent)\(suffix).tar.gz")!
        #else
        throw ToolchainError(description: "toolchain installation is not supported on this platform")
        #endif
    }

    /// Returns the directory containing `usr/`.
    private static func unpack(_ archive: URL, in staging: URL) async throws -> URL {
        let expanded = staging.appendingPathComponent("expanded", isDirectory: true)

        #if os(macOS)
        // Only install packages signed by Apple.
        let signature = try await ProcessRunner.run(["pkgutil", "--check-signature", archive.path], exitPolicy: .allowFailure)
        guard signature.succeeded, signature.output.contains("Apple") else {
            throw ToolchainError(description: "\(archive.lastPathComponent) is not signed by Apple")
        }

        // `--expand-full` unpacks the payload without installing system-wide.
        try await ProcessRunner.run(["pkgutil", "--expand-full", archive.path, expanded.path])
        let components = (try? FileManager.default.contentsOfDirectory(atPath: expanded.path)) ?? []
        for component in components {
            let payload = expanded.appendingPathComponent(component).appendingPathComponent("Payload", isDirectory: true)
            if FileSystem.exists(payload.appendingPathComponent(Path.binary).appendingPathComponent("swift")) {
                return payload
            }
        }
        throw ToolchainError(description: "no toolchain payload in \(archive.lastPathComponent)")
        #else
        try FileSystem.createDirectory(expanded)
        try await ProcessRunner.run(["tar", "-xzf", archive.path, "-C", expanded.path, "--strip-components=1"])
        return expanded
        #endif
    }

    // MARK: Selection

    /// The nearest `.swift-version` at or above `directory`.
    public static func requestedVersion(from directory: URL) -> (request: String, file: URL)? {
        var current = directory.standardizedFileURL
        while true {
            let file = current.appendingPathComponent(Path.swiftVersionFile)
            if let data = FileSystem.readIfPresent(file) {
                let request = String(decoding: data, as: UTF8.self)
                    .split(whereSeparator: \.isNewline).first.map(String.init)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                if !request.isEmpty {
                    return (request, file)
                }
            }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { return nil }
            current = parent
        }
    }

    public static func writeRequest(_ request: String, in directory: URL) throws -> URL {
        let file = directory.appendingPathComponent(Path.swiftVersionFile)
        try FileSystem.writeAtomically(Data((request + "\n").utf8), to: file)
        return file
    }

    /// The version of whatever `swift` is on `PATH` right now.
    public static func systemVersion() async -> String? {
        guard let result = try? await ProcessRunner.run(["swift", "--version"], exitPolicy: .allowFailure) else { return nil }
        let text = result.output + result.errorOutput
        guard let range = text.range(of: Swift.versionPrefix) else { return nil }
        return String(text[range.upperBound...].prefix { $0.isNumber || $0 == "." })
    }

    /// Does `request` name the release `version` belongs to?
    public static func satisfies(_ version: String, request: String) -> Bool {
        // A release on PATH never stands in for a snapshot.
        guard SnapshotRequest(request) == nil else { return false }
        return Self.match(request, in: [ToolchainRelease(name: version, tag: "")]) != nil
    }

    /// Puts the toolchain first on `PATH` for this process and everything it spawns.
    public static func activate(_ toolchain: InstalledToolchain) {
        let current = ProcessInfo.processInfo.environment[Environment.path] ?? ""
        setenv(Environment.path, toolchain.binDirectory.path + Swift.pathSeparator + current, 1)
        // Xcode's `xcrun` shims honour TOOLCHAINS; unset it so it can't override PATH.
        unsetenv(Environment.toolchains)
    }
}

/// Special requests understood in `.swift-version` and `swx toolchain install`.
public enum ToolchainRequest {
    public static let latest = "latest"
}

#if os(Linux)
/// swift.org's naming of Linux distributions (`ubuntu2404` / `ubuntu24.04`).
struct LinuxPlatform {
    let directory: String
    let fileComponent: String
    let isArm: Bool

    private static let osRelease = "/etc/os-release"

    static func current() throws -> LinuxPlatform {
        let text = (try? String(contentsOfFile: Self.osRelease, encoding: .utf8)) ?? ""
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            fields[String(parts[0])] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        guard let id = fields["ID"], let version = fields["VERSION_ID"] else {
            throw ToolchainError(description: "unknown Linux distribution")
        }
        #if arch(arm64)
        let isArm = true
        #else
        let isArm = false
        #endif
        let compact = version.replacingOccurrences(of: ".", with: "")
        return LinuxPlatform(directory: id + compact, fileComponent: id + version, isArm: isArm)
    }
}
#endif
