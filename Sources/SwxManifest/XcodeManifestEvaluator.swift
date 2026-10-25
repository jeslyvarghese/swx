import Foundation
import SwxCore
import SwxSystem

/// Evaluates manifests the command-line SwiftPM can't load: those importing `AppleProductTypes`
/// (Xcode and Swift Playgrounds apps).
///
/// Like SwiftPM's own manifest loader, it compiles the manifest against Xcode's ManifestAPI
/// (which also ships `AppleProductTypes`), runs it in a sandbox with `-fileno`, and decodes the
/// package that PackageDescription serializes.
public enum XcodeManifestEvaluator {
    private enum Path {
        static let manifestAPI = "../SharedFrameworks/SwiftPM.framework/SharedSupport/ManifestAPI"
        static let executable = "manifest"
        static let prefix = "swx-xcode-manifest"
    }

    private enum Tool {
        static let xcodeSelect = "/usr/bin/xcode-select"
        static let printPath = "-p"
        static let xcrun = "/usr/bin/xcrun"
        static let swiftc = "swiftc"
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
    }

    private enum Argument {
        static let fileno = "-fileno"
        static let standardOutput = "1"
        static let context = "-context"
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

    /// Whether `contents` needs this evaluator (the command-line SwiftPM can't import the module).
    public static func isNeeded(for contents: String) -> Bool {
        contents.split(whereSeparator: \.isNewline).contains { line in
            // `[@attribute …] import AppleProductTypes`, not in a comment.
            let tokens = line.split(whereSeparator: \.isWhitespace)
            guard let importIndex = tokens.firstIndex(of: Substring(Self.importKeyword)),
                  tokens.index(after: importIndex) < tokens.endIndex,
                  tokens[tokens.index(after: importIndex)] == Substring(Library.appleProductTypes) else {
                return false
            }
            return tokens[..<importIndex].allSatisfy { $0.hasPrefix(Self.attributePrefix) }
        }
    }

    /// Xcode's ManifestAPI directory, when Xcode is installed.
    static func manifestAPI() async -> URL? {
        #if os(macOS)
        guard let developer = try? await ProcessRunner.run([Tool.xcodeSelect, Tool.printPath], exitPolicy: .allowFailure), developer.succeeded else {
            return nil
        }
        let directory = URL(fileURLWithPath: developer.output.trimmingCharacters(in: .whitespacesAndNewlines))
            .appendingPathComponent(Path.manifestAPI)
            .standardizedFileURL
        return FileSystem.isDirectory(directory) ? directory : nil
        #else
        return nil
        #endif
    }

    /// Evaluates `contents` as the manifest of the package at `packageDirectory`.
    public static func evaluate(contents: String, packageDirectory: URL) async throws -> Manifest {
        guard let api = await Self.manifestAPI() else {
            throw ManifestError(description: "this manifest imports AppleProductTypes, which needs Xcode (not found)")
        }
        let scratch = try FileSystem.makeTemporaryDirectory(prefix: Path.prefix)
        defer { try? FileSystem.removeTree(scratch) }

        // Compile against Xcode's PackageDescription and AppleProductTypes.
        let source = scratch.appendingPathComponent(WellKnownFile.manifest)
        try Data(contents.utf8).write(to: source)
        let executable = scratch.appendingPathComponent(Path.executable)
        let toolsVersion = ToolsVersion.parse(manifest: contents)
        let sdk = try await ProcessRunner.run([Tool.xcrun, Tool.sdk, Tool.macOSSDK, Tool.showSDKPath]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        var compile = [
            Tool.xcrun, Tool.swiftc,
            "-swift-version", toolsVersion >= Self.swift6ToolsVersion ? Self.swift6Mode : Self.swift5Mode,
            "-package-description-version", toolsVersion.description,
            "-sdk", sdk,
            "-I", api.path, "-L", api.path,
            "-Xlinker", "-rpath", "-Xlinker", api.path,
        ]
        for library in [Library.packageDescription, Library.appleProductTypes, Library.compilerPluginSupport] {
            compile.append("-l" + library)
        }
        compile += [source.path, "-o", executable.path]
        let compiled = try await ProcessRunner.run(compile, exitPolicy: .allowFailure)
        guard compiled.succeeded else {
            throw ManifestError(description: "manifest compilation failed:\n\(compiled.errorOutput)")
        }

        // Run it sandboxed; it writes the serialized package to the given descriptor.
        let context = try JSONEncoder().encode([ContextKey.packageDirectory: packageDirectory.path])
        let run = try await ProcessRunner.run(
            [Tool.sandbox, Tool.profileFlag, Self.sandboxProfile, executable.path,
             Argument.fileno, Argument.standardOutput, Argument.context, String(decoding: context, as: UTF8.self)],
            exitPolicy: .allowFailure
        )
        guard run.succeeded else {
            throw ManifestError(description: "manifest evaluation failed:\n\(run.errorOutput)")
        }
        return try SerializedManifestDecoder.decode(run.standardOutput, packageDirectory: packageDirectory, toolsVersion: toolsVersion)
    }

    private enum ContextKey {
        static let packageDirectory = "packageDirectory"
    }
}
