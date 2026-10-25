import Foundation
import SwxCore
import SwxSystem

/// Which PackageDescription a manifest is compiled against.
public enum ManifestAPI: Sendable {
    /// The active toolchain's `lib/swift/pm/ManifestAPI` (what `swift package` uses).
    case toolchain
    /// Xcode's, which also ships `AppleProductTypes` (Xcode and Swift Playgrounds apps).
    case xcode
}

/// Evaluates a manifest the way SwiftPM's manifest loader does, without starting SwiftPM:
/// compile it against a ManifestAPI, run it (sandboxed on macOS) with `-fileno` and `-context`,
/// and decode the package that PackageDescription serializes.
///
/// About a third faster than `swift package dump-package` for a cold manifest, and the only
/// way to evaluate `AppleProductTypes` manifests, which the command-line SwiftPM can't import.
public enum ManifestCompiler {
    private enum Path {
        static let xcodeManifestAPI = "../SharedFrameworks/SwiftPM.framework/SharedSupport/ManifestAPI"
        static let toolchainManifestAPI = "../lib/swift/pm/ManifestAPI"
        static let executable = "manifest"
        static let prefix = "swx-manifest-build"
    }

    private enum Tool {
        static let swift = "swift"
        static let swiftc = "swiftc"
        static let xcodeSelect = "/usr/bin/xcode-select"
        static let printPath = "-p"
        static let xcrun = "/usr/bin/xcrun"
        static let find = "--find"
        static let showSDKPath = "--show-sdk-path"
        static let sdk = "--sdk"
        static let macOSSDK = "macosx"
        static let sandbox = "/usr/bin/sandbox-exec"
        static let profileFlag = "-p"
    }

    private enum Library {
        static let packageDescription = "PackageDescription"
        static let appleProductTypes = "AppleProductTypes"
        static let compilerPluginSupport = "CompilerPluginSupport"
        static let prefix = "lib"
        #if os(macOS)
        static let suffix = ".dylib"
        #else
        static let suffix = ".so"
        #endif
    }

    private enum Argument {
        static let fileno = "-fileno"
        static let standardOutput = "1"
        static let context = "-context"
    }

    private enum ContextKey {
        static let packageDirectory = "packageDirectory"
    }

    /// Manifests from tools 6.0 on use the Swift 6 language mode, as SwiftPM compiles them.
    private static let swift6ToolsVersion = ToolsVersion(6, 0)
    private static let swift6Mode = "6"
    private static let swift5Mode = "5"
    private static let importKeyword = "import"
    private static let attributePrefix = "@"

    /// SwiftPM's sandbox for running compiled manifests: read anything, write nothing, no network.
    private static let sandboxProfile = """
        (version 1)
        (deny default)
        (import "system.sb")
        (allow file-read*)
        (allow process*)
        (allow mach-lookup (global-name "com.apple.lsd.mapdb"))
        (allow mach-lookup (global-name "com.apple.mobileassetd.v2"))
        """

    /// Whether `contents` needs Xcode's ManifestAPI (`[@attribute …] import AppleProductTypes`).
    public static func needsXcode(_ contents: String) -> Bool {
        contents.split(whereSeparator: \.isNewline).contains { line in
            let tokens = line.split(whereSeparator: \.isWhitespace)
            guard let importIndex = tokens.firstIndex(of: Substring(Self.importKeyword)),
                  tokens.index(after: importIndex) < tokens.endIndex,
                  tokens[tokens.index(after: importIndex)] == Substring(Library.appleProductTypes) else {
                return false
            }
            return tokens[..<importIndex].allSatisfy { $0.hasPrefix(Self.attributePrefix) }
        }
    }

    // MARK: Locations

    /// The ManifestAPI directory, or `nil` when it isn't installed.
    static func directory(of api: ManifestAPI) async -> URL? {
        switch api {
        case .toolchain:
            // Next to the `swift` on PATH (which `.swift-version` activation puts first)…
            if let swift = ExecutableLookup.find(Tool.swift)?.resolvingSymlinksInPath(), let directory = Self.manifestAPI(besides: swift) {
                return directory
            }
            #if os(macOS)
            // …or, behind Xcode's `/usr/bin/swift` shim, next to the toolchain binary it runs.
            guard let found = try? await ProcessRunner.run([Tool.xcrun, Tool.find, Tool.swift], exitPolicy: .allowFailure), found.succeeded else {
                return nil
            }
            return Self.manifestAPI(besides: URL(fileURLWithPath: found.output.trimmingCharacters(in: .whitespacesAndNewlines)))
            #else
            return nil
            #endif
        case .xcode:
            #if os(macOS)
            guard let developer = try? await ProcessRunner.run([Tool.xcodeSelect, Tool.printPath], exitPolicy: .allowFailure), developer.succeeded else {
                return nil
            }
            let directory = URL(fileURLWithPath: developer.output.trimmingCharacters(in: .whitespacesAndNewlines))
                .appendingPathComponent(Path.xcodeManifestAPI)
                .standardizedFileURL
            return FileSystem.isDirectory(directory) ? directory : nil
            #else
            return nil
            #endif
        }
    }

    private static func manifestAPI(besides swift: URL) -> URL? {
        let directory = swift.deletingLastPathComponent().appendingPathComponent(Path.toolchainManifestAPI).standardizedFileURL
        return FileSystem.isDirectory(directory) ? directory : nil
    }

    // MARK: Evaluation

    /// Evaluates `contents` as the manifest of the package at `packageDirectory`.
    public static func evaluate(contents: String, packageDirectory: URL, api: ManifestAPI) async throws -> Manifest {
        guard let directory = await Self.directory(of: api) else {
            throw ManifestError(description: Self.missingAPIMessage(api))
        }
        let scratch = try FileSystem.makeTemporaryDirectory(prefix: Path.prefix)
        defer { try? FileSystem.removeTree(scratch) }

        // Compile against that PackageDescription, linking whichever API libraries ship there.
        let source = scratch.appendingPathComponent(WellKnownFile.manifest)
        try Data(contents.utf8).write(to: source)
        let executable = scratch.appendingPathComponent(Path.executable)
        let toolsVersion = ToolsVersion.parse(manifest: contents)
        var compile = try await Self.compiler(for: api) + [
            "-swift-version", toolsVersion >= Self.swift6ToolsVersion ? Self.swift6Mode : Self.swift5Mode,
            "-package-description-version", toolsVersion.description,
            "-I", directory.path, "-L", directory.path,
            "-Xlinker", "-rpath", "-Xlinker", directory.path,
        ]
        for library in [Library.packageDescription, Library.appleProductTypes, Library.compilerPluginSupport]
        where FileSystem.exists(directory.appendingPathComponent(Library.prefix + library + Library.suffix)) {
            compile.append("-l" + library)
        }
        compile += [source.path, "-o", executable.path]
        let compiled = try await ProcessRunner.run(compile, exitPolicy: .allowFailure)
        guard compiled.succeeded else {
            throw ManifestError(description: "manifest compilation failed:\n\(compiled.errorOutput)")
        }

        // Run it; it writes the serialized package to the given descriptor.
        let context = try JSONEncoder().encode([ContextKey.packageDirectory: packageDirectory.path])
        let run = try await ProcessRunner.run(
            Self.sandboxed([executable.path, Argument.fileno, Argument.standardOutput, Argument.context, String(decoding: context, as: UTF8.self)]),
            exitPolicy: .allowFailure
        )
        guard run.succeeded else {
            throw ManifestError(description: "manifest evaluation failed:\n\(run.errorOutput)")
        }
        return try SerializedManifestDecoder.decode(run.standardOutput, packageDirectory: packageDirectory, toolsVersion: toolsVersion)
    }

    /// `swiftc` for the API: Xcode's through `xcrun` with the macOS SDK; the toolchain's from PATH.
    private static func compiler(for api: ManifestAPI) async throws -> [String] {
        #if os(macOS)
        let sdk = try await ProcessRunner.run([Tool.xcrun, Tool.sdk, Tool.macOSSDK, Tool.showSDKPath]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        switch api {
        case .xcode:
            return [Tool.xcrun, Tool.swiftc, "-sdk", sdk]
        case .toolchain:
            return [Tool.swiftc, "-sdk", sdk]
        }
        #else
        return [Tool.swiftc]
        #endif
    }

    /// SwiftPM sandboxes manifests on macOS only.
    private static func sandboxed(_ command: [String]) -> [String] {
        #if os(macOS)
        return [Tool.sandbox, Tool.profileFlag, Self.sandboxProfile] + command
        #else
        return command
        #endif
    }

    private static func missingAPIMessage(_ api: ManifestAPI) -> String {
        switch api {
        case .toolchain:
            return "the toolchain has no ManifestAPI next to `swift`"
        case .xcode:
            return "this manifest imports AppleProductTypes, which needs Xcode (not found)"
        }
    }
}
