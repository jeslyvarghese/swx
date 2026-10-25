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

    private enum CompilerFlag {
        static let pass = "-Xswiftc"
        static let explicitModules = "-explicit-module-build"
        static let cacheJobs = "-cache-compile-job"
        static let casPath = "-cas-path"
        static let prefixMap = "-scanner-prefix-map"
        /// Paths under the package root are hashed relative to this, so dependencies built in one
        /// project hit the cache in another.
        static let mappedRoot = "/^package"
    }

    private enum BuildSystem {
        static let option = "--build-system"
        static let native = "native"
    }

    /// Compiler-level caching (`swiftc -cache-compile-job`), for SwiftPM's native build system:
    /// swift-build's compile jobs can't run cached with SwiftPM 6.4.
    public static func compilerCacheArguments(cache: URL, packageDirectory: URL) -> [String] {
        let flags = [
            CompilerFlag.explicitModules,
            CompilerFlag.cacheJobs,
            CompilerFlag.casPath, cache.path,
            CompilerFlag.prefixMap, packageDirectory.path + "=" + CompilerFlag.mappedRoot,
        ]
        return flags.flatMap { [CompilerFlag.pass, $0] }
    }

    public static let nativeBuildSystemArguments = [BuildSystem.option, BuildSystem.native]

    /// Whether the arguments select SwiftPM's native build system.
    public static func usesNativeBuildSystem(_ arguments: [String]) -> Bool {
        if let index = arguments.firstIndex(of: BuildSystem.option), index + 1 < arguments.count {
            return arguments[index + 1] == BuildSystem.native
        }
        return arguments.contains(BuildSystem.option + "=" + BuildSystem.native)
    }

    /// Feature detection from `swiftc -help-hidden` (Swift 6.x compilers can cache jobs in a CAS).
    public static func supportsCompilerCaching() async -> Bool {
        guard let help = try? await ProcessRunner.run(["swiftc", "-help-hidden"], exitPolicy: .allowFailure) else { return false }
        return help.output.contains(CompilerFlag.cacheJobs) && help.output.contains(CompilerFlag.prefixMap)
    }

    /// Feature detection from `swift build --help` (newer SwiftPM ships `--build-cache-path`).
    public static func supportsBuildCaching() async -> Bool {
        guard let help = try? await ProcessRunner.run(["swift", "build", "--help"], exitPolicy: .allowFailure) else { return false }
        return help.output.contains(Flag.buildCachePath)
    }
}
