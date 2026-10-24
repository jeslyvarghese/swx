import Foundation
import SwxSystem

/// Host builds through SwiftPM (which embeds swift-build), with resolution disabled because
/// swx already resolved. Turns on a shared compilation cache when the toolchain supports it.
public struct SwiftPMBuildDriver: BuildDriver {
    private enum Flag {
        static let disableResolution = "--disable-automatic-resolution"
        static let enableBuildCaching = "--enable-build-caching"
        static let buildCachePath = "--build-cache-path"
        static let prefixMapping = "--enable-build-cache-prefix-mapping"
    }

    /// The store's CAS, shared by every project; `nil` disables caching.
    public let compilationCache: URL?

    public init(compilationCache: URL?) {
        self.compilationCache = compilationCache
    }

    public func run(_ request: BuildRequest) async throws -> BuildResult {
        let arguments = try await self.arguments(for: request)
        let status = try await ProcessRunner.runStreaming(arguments, in: request.packageDirectory)
        guard status == 0 else {
            throw BuildError(description: "swift \(request.action.rawValue) failed (exit \(status))")
        }
        let binPath = try await ProcessRunner.run(["swift", "build", "--show-bin-path", "-c", request.configuration], in: request.packageDirectory)
        return BuildResult(productsDirectory: URL(fileURLWithPath: binPath.output.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// The full `swift build|test …` command line, for executing in-process or via exec.
    public func arguments(for request: BuildRequest) async throws -> [String] {
        var arguments = ["swift", request.action.rawValue, "-c", request.configuration]
        if let product = request.product {
            arguments += ["--product", product]
        }
        if !request.extraArguments.contains(Flag.disableResolution) {
            arguments.append(Flag.disableResolution)
        }
        arguments += try await self.cacheArguments(existing: request.extraArguments)
        return arguments + request.extraArguments
    }

    /// Cross-project compilation caching flags, unless the user configured caching themselves.
    /// Callers check `supportsBuildCaching()` first (and should remember the answer).
    public func cacheArguments(existing: [String]) async throws -> [String] {
        guard let compilationCache,
              !existing.contains(where: { $0.contains("build-cach") }) else {
            return []
        }
        return [Flag.enableBuildCaching, Flag.buildCachePath, compilationCache.path, Flag.prefixMapping]
    }

    /// Feature detection from `swift build --help` (newer SwiftPM ships `--build-cache-path`).
    public static func supportsBuildCaching() async -> Bool {
        guard let help = try? await ProcessRunner.run(["swift", "build", "--help"], exitPolicy: .allowFailure) else { return false }
        return help.output.contains(Flag.buildCachePath)
    }
}
