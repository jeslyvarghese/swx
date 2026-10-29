import Foundation
import SwxApple
import SwxSystem

/// Builds packages for Apple platforms with xcodebuild, which understands `AppleProductTypes`
/// (app bundles, Info.plist, asset catalogs, signing) natively.
///
/// Dependencies must already be checked out in `sourcePackages` by swx; xcodebuild is told
/// never to resolve on its own.
public struct XcodeBuildDriver: BuildDriver {
    private enum Flag {
        static let clonedSourcePackages = "-clonedSourcePackagesDirPath"
        static let derivedData = "-derivedDataPath"
        static let disableResolution = "-disableAutomaticPackageResolution"
        static let onlyResolvedVersions = "-onlyUsePackageVersionsFromResolvedFile"
        static let skipMacroValidation = "-skipMacroValidation"
        static let allowProvisioningUpdates = "-allowProvisioningUpdates"
        static let quiet = "-quiet"
        static let resultBundle = "-resultBundlePath"
    }

    private enum Layout {
        static let buildProducts = "Build/Products"
        static let buildLog = "swx-build.log"
    }

    /// Settings that make an app hot-reloadable without touching its project: calls between
    /// functions go through rebindable references (`-interposable`), internal functions are
    /// exported (testability), and the code lives in the executable rather than a debug dylib.
    private enum HotReloadSetting {
        static let linkerFlags = "OTHER_LDFLAGS=$(inherited) -Xlinker -interposable"
        static let testability = "ENABLE_TESTABILITY=YES"
        static let debugDylib = "ENABLE_DEBUG_DYLIB=NO"
    }

    /// What `-quiet` would still show: the lines a full log is worth echoing (`file:1:2: error: …`).
    private enum Diagnostic {
        static let error = ": error:"
        static let warning = ": warning:"
        static let toolError = "error:"
    }

    /// Xcode's compilation cache (LLVM CAS) build settings.
    private enum CacheSetting {
        static let enable = "COMPILATION_CACHE_ENABLE_CACHING"
        static let casPath = "COMPILATION_CACHE_CAS_PATH"
        static let enabled = "YES"
        static let assignment = "="
    }

    public let sourcePackages: URL
    public let derivedData: URL
    /// Lets xcodebuild create or download provisioning profiles for device builds.
    public let signing: DeviceSigning

    public enum DeviceSigning: Sendable {
        case automatic(team: String?)
        case manual
    }

    /// How much of xcodebuild's log to show.
    public enum Output: Sendable, Equatable {
        /// Warnings, errors and test results only (`-quiet`).
        case quiet
        case full
        /// What `-quiet` shows goes to `log` instead of the terminal, and test runs write a
        /// result bundle: for reports read by tools (`--format json`).
        case captured(log: URL, resultBundle: URL?)
    }

    public let output: Output

    /// Whether compile jobs are cached in a content-addressed store outside DerivedData.
    public enum CompilationCache: Sendable {
        case disabled
        /// Xcode's own compilation cache, kept in `directory` so it outlives a deleted
        /// DerivedData (`rm -rf .build`, a fresh CI checkout restoring only the cache).
        case enabled(directory: URL)
    }

    public let compilationCache: CompilationCache

    public init(sourcePackages: URL, derivedData: URL, signing: DeviceSigning, output: Output, compilationCache: CompilationCache) {
        self.sourcePackages = sourcePackages
        self.derivedData = derivedData
        self.signing = signing
        self.output = output
        self.compilationCache = compilationCache
    }

    public func run(_ request: BuildRequest) async throws -> BuildResult {
        guard let destination = request.destination else {
            throw BuildError(description: "an Apple platform destination is required")
        }
        let scheme = try await self.scheme(for: request)

        var arguments = ["xcodebuild", request.action.rawValue] + Self.containerArguments(request.container) + [
            "-scheme", scheme,
            "-configuration", request.configuration.capitalized,
            "-destination", destination.xcodebuildDestination,
            Flag.derivedData, self.derivedData.path,
            Flag.clonedSourcePackages, self.sourcePackages.path,
            Flag.disableResolution, Flag.onlyResolvedVersions, Flag.skipMacroValidation,
        ]

        // Simulators sign ad hoc by themselves; devices need a team.
        if destination.environment == .device, destination.platform != .macOS, case .automatic(let team) = self.signing {
            arguments.append(Flag.allowProvisioningUpdates)
            if let team {
                arguments.append("DEVELOPMENT_TEAM=\(team)")
            }
        }
        if self.output != .full && request.codeLoading == .standard {
            arguments.append(Flag.quiet)
        }
        if case .captured(_, let resultBundle?) = self.output, request.action == .test {
            // xcodebuild refuses to write over an existing bundle.
            try? FileManager.default.removeItem(at: resultBundle)
            arguments += [Flag.resultBundle, resultBundle.path]
        }
        arguments += self.cacheSettings(existing: request.extraArguments)
        if request.codeLoading == .hotReloadable {
            arguments += [HotReloadSetting.linkerFlags, HotReloadSetting.testability, HotReloadSetting.debugDylib]
        }
        arguments += request.extraArguments

        let products = self.derivedData.appendingPathComponent(Layout.buildProducts)
            .appendingPathComponent(destination.productsDirectoryName(configuration: request.configuration.capitalized))

        // Captured: the log is the report's source, the terminal sees nothing.
        if case .captured(let log, _) = self.output, request.codeLoading == .standard {
            try FileSystem.createDirectory(log.deletingLastPathComponent())
            let status = try await ProcessRunner.runLogged(arguments, in: request.packageDirectory, log: log) { _ in false }
            guard status == 0 else {
                throw BuildError(description: "xcodebuild \(request.action.rawValue) failed (exit \(status)); full log: \(log.path)", log: log)
            }
            return BuildResult(productsDirectory: products)
        }

        // Stream xcodebuild's output live: builds take a while and errors must be visible.
        guard request.codeLoading == .hotReloadable else {
            let status = try await ProcessRunner.runStreaming(arguments, in: request.packageDirectory)
            guard status == 0 else {
                throw BuildError(description: "xcodebuild \(request.action.rawValue) failed (exit \(status))")
            }
            return BuildResult(productsDirectory: products)
        }

        // Hot reload needs the full log, which names each module's compile command; the
        // terminal still sees only what `-quiet` would show.
        let log = self.derivedData.appendingPathComponent(Layout.buildLog)
        try FileSystem.createDirectory(self.derivedData)
        let output = self.output
        let status = try await ProcessRunner.runLogged(arguments, in: request.packageDirectory, log: log) { line in
            output == .full || line.hasPrefix(Diagnostic.toolError) || line.contains(Diagnostic.error) || line.contains(Diagnostic.warning)
        }
        guard status == 0 else {
            throw BuildError(description: "xcodebuild \(request.action.rawValue) failed (exit \(status)); full log: \(log.path)", log: log)
        }
        let logged = XcodeBuildLog.swiftModuleCommands(in: String(decoding: FileSystem.readIfPresent(log) ?? Data(), as: UTF8.self))
        let modules = SwiftModuleCommandStore(derivedData: self.derivedData).merge(logged)
        return BuildResult(productsDirectory: products, swiftModules: modules)
    }

    /// Settings turning the compilation cache on, unless the user configures it themselves.
    private func cacheSettings(existing: [String]) -> [String] {
        guard case .enabled(let directory) = self.compilationCache else { return [] }
        guard !existing.contains(where: { $0.hasPrefix(CacheSetting.enable + CacheSetting.assignment) }) else { return [] }
        return [
            CacheSetting.enable + CacheSetting.assignment + CacheSetting.enabled,
            CacheSetting.casPath + CacheSetting.assignment + directory.path,
        ]
    }

    /// The product's scheme for builds; the package's test scheme for tests.
    private func scheme(for request: BuildRequest) async throws -> String {
        let schemes = try await self.cachedSchemes(for: request)
        if request.action == .test, let packageScheme = schemes.first(where: { $0.hasSuffix(Self.packageSchemeSuffix) }) {
            return packageScheme
        }
        if let product = request.product {
            guard schemes.contains(product) else {
                throw BuildError(description: "no scheme '\(product)' (available: \(schemes.joined(separator: ", ")))")
            }
            return product
        }
        guard let first = schemes.first else {
            throw BuildError(description: "xcodebuild found no schemes in \(request.packageDirectory.path)")
        }
        return first
    }

    private static let packageSchemeSuffix = "-Package"

    /// The remembered scheme list, or a fresh one. A remembered list missing the requested
    /// product is listed again, so a stale entry can't turn into a wrong "no scheme" error.
    private func cachedSchemes(for request: BuildRequest) async throws -> [String] {
        let cache = SchemeListCache(derivedData: self.derivedData)
        if let remembered = await cache.schemes(directory: request.packageDirectory, container: request.container),
           request.product.map(remembered.contains) ?? true {
            return remembered
        }

        let schemes = try await Self.schemes(in: request.packageDirectory, container: request.container)
        await cache.remember(schemes, directory: request.packageDirectory, container: request.container)
        return schemes
    }

    private static let workspaceExtension = "xcworkspace"

    /// `-workspace X` / `-project X`, or nothing for a package directory.
    static func containerArguments(_ container: URL?) -> [String] {
        guard let container else { return [] }
        let flag = container.pathExtension == Self.workspaceExtension ? "-workspace" : "-project"
        return [flag, container.path]
    }

    static func schemes(in directory: URL, container: URL?) async throws -> [String] {
        let result = try await ProcessRunner.run(
            ["xcodebuild", "-list", "-json", Flag.disableResolution] + Self.containerArguments(container),
            in: directory,
            exitPolicy: .allowFailure
        )
        // xcodebuild prints log lines before the JSON object.
        let output = result.output
        guard let start = output.firstIndex(of: "{"),
              let json = try? JSONSerialization.jsonObject(with: Data(output[start...].utf8)) as? [String: Any] else {
            throw BuildError(description: "could not list schemes: \(result.errorOutput.prefix(500))")
        }
        let container = (json["workspace"] ?? json["project"]) as? [String: Any]
        return container?["schemes"] as? [String] ?? []
    }
}
