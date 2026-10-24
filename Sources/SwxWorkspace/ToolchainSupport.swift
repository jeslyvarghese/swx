import Foundation
import SwxSystem
import SwxToolchain

/// The toolchain a command will run with.
public enum ToolchainSelection: Sendable, CustomStringConvertible {
    /// No `.swift-version`, or it matches the `swift` already on PATH.
    case system(version: String?)
    /// A swx-managed toolchain, now first on PATH.
    case managed(name: String, path: URL)

    public var description: String {
        switch self {
        case .system(let version):
            return "system (\(version ?? "unknown"))"
        case .managed(let name, let path):
            return "\(name) (\(path.path))"
        }
    }
}

/// What to do when `.swift-version` names a toolchain that isn't installed.
public enum MissingToolchainPolicy: Sendable {
    case install
    case fail
}

/// `swx toolchain …` and automatic `.swift-version` handling.
public struct Toolchains: Sendable {
    private let manager = ToolchainManager()

    public init() {}

    /// Honors the nearest `.swift-version`: uses the system toolchain if it matches,
    /// otherwise activates (and if needed installs) the requested one for this process.
    @discardableResult
    public func prepare(for directory: URL, missing: MissingToolchainPolicy, progress: @Sendable (String) -> Void) async throws -> ToolchainSelection {
        // Without `.swift-version` there is nothing to decide (and no process to spawn).
        guard let (request, file) = ToolchainManager.requestedVersion(from: directory) else {
            return .system(version: nil)
        }
        let systemVersion = await ToolchainManager.systemVersion()

        // The toolchain on PATH already satisfies the request.
        if let systemVersion, ToolchainManager.satisfies(systemVersion, request: request) {
            return .system(version: systemVersion)
        }

        // A managed toolchain, installed on demand like uv does for Python.
        let toolchain: InstalledToolchain
        if let installed = self.manager.installed(request) {
            toolchain = installed
        } else {
            guard missing == .install else {
                throw ToolchainError(description: "\(file.path) requests Swift \(request), which is not installed (run `swx toolchain install \(request)`)")
            }
            progress("\(file.lastPathComponent) requests Swift \(request); installing it")
            toolchain = try await self.manager.install(request, progress: progress)
        }
        ToolchainManager.activate(toolchain)
        return .managed(name: toolchain.name, path: toolchain.root)
    }

    public func install(_ request: String, progress: @Sendable (String) -> Void) async throws -> (name: String, path: URL) {
        let toolchain = try await self.manager.install(request, progress: progress)
        return (toolchain.name, toolchain.root)
    }

    public func uninstall(_ request: String) throws {
        try self.manager.uninstall(request)
    }

    public func installed() -> [(name: String, path: URL)] {
        self.manager.installed().map { ($0.name, $0.root) }
    }

    /// The newest releases, newest first.
    public func available(limit: Int) async throws -> [String] {
        Array(try await self.manager.availableReleases().map(\.name).reversed().prefix(limit))
    }

    /// Pins a version for `directory` (writes `.swift-version`).
    public func use(_ request: String, in directory: URL) throws -> URL {
        try ToolchainManager.writeRequest(request, in: directory)
    }

    public func requested(from directory: URL) -> (request: String, file: URL)? {
        ToolchainManager.requestedVersion(from: directory)
    }
}
