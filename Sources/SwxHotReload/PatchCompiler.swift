import Foundation
import SwxBuild
import SwxSystem

/// Compiles one changed file into a patch dylib, with exactly the flags the build compiled its
/// module with. The patch is linked alone: everything it calls resolves against the running app.
public actor PatchCompiler {
    private enum Flag {
        static let printJobs = "-driver-print-jobs"
        static let primaryFile = "-primary-file"
        static let output = "-o"
        static let emitLibrary = "-emit-library"
        static let target = "-target"
        static let sdk = "-sdk"
        static let linker = "-Xlinker"
        /// Undefined symbols are looked up in the loaded images (the app) when the patch loads.
        static let undefinedLookup = ["-undefined", "dynamic_lookup"]

        /// Side outputs of the build's job (index, diagnostics, dependencies, const values) the
        /// patch has no use for; each takes a value.
        static let sideOutputs: Set<String> = [
            "-o", "-index-store-path", "-index-unit-output-path", "-serialize-diagnostics-path",
            "-emit-dependencies-path", "-emit-reference-dependencies-path", "-const-gather-protocols-file",
            "-emit-const-values-path", "-supplementary-output-file-map",
        ]
    }

    private enum Layout {
        /// The agent recognizes patches by this name.
        static let prefix = "swx-hot-patch-"
        static let objectExtension = "o"
        static let libraryExtension = "dylib"
    }

    private let modules: [SwiftModuleCommand]
    private let moduleOfFile: [String: Int]
    private let directory: URL
    private var patches = 0

    /// `modules` for one architecture; patches are written to `directory`.
    public init(modules: [SwiftModuleCommand], directory: URL) {
        self.modules = modules
        self.directory = directory
        var moduleOfFile: [String: Int] = [:]
        for (index, module) in modules.enumerated() {
            for file in module.sourceFiles() {
                moduleOfFile[file.path] = index
            }
        }
        self.moduleOfFile = moduleOfFile
    }

    /// Every source file of the modules.
    public nonisolated var sourceFiles: [URL] {
        self.moduleOfFile.keys.sorted().map { URL(fileURLWithPath: $0) }
    }

    public nonisolated func module(containing file: URL) -> SwiftModuleCommand? {
        self.moduleOfFile[Self.resolved(file).path].map { self.modules[$0] }
    }

    /// Compiles `file` and links it into a new patch.
    public func compile(_ file: URL) async throws -> URL {
        guard let module = self.module(containing: file) else {
            throw HotReloadError(description: "\(file.lastPathComponent) is not part of any module that was built")
        }
        let workingDirectory = URL(fileURLWithPath: module.workingDirectory)

        // The build's own frontend job for this file, with only the object file as output.
        let jobs = try await self.frontendJobs(for: module)
        self.patches += 1
        let name = Layout.prefix + "\(self.patches)-" + file.deletingPathExtension().lastPathComponent
        let object = self.directory.appendingPathComponent(name).appendingPathExtension(Layout.objectExtension)
        let library = self.directory.appendingPathComponent(name).appendingPathExtension(Layout.libraryExtension)
        guard let job = jobs.lazy.compactMap({ Self.patchJob(from: $0, primary: file, object: object, workingDirectory: workingDirectory) }).first else {
            throw HotReloadError(description: "the build of \(module.module) has no compile job for \(file.lastPathComponent)")
        }
        try FileSystem.createDirectory(self.directory)
        let compile = try await ProcessRunner.run(job, in: workingDirectory, exitPolicy: .allowFailure)
        guard compile.succeeded else {
            throw HotReloadError(description: compile.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Linked alone, with the module's target and SDK.
        guard let target = module.target, let sdk = module.sdk, let swiftc = module.arguments.first else {
            throw HotReloadError(description: "the build of \(module.module) names no target or SDK")
        }
        let link = [swiftc, Flag.emitLibrary, object.path, Flag.output, library.path, Flag.target, target, Flag.sdk, sdk]
            + Flag.undefinedLookup.flatMap { [Flag.linker, $0] }
        let linked = try await ProcessRunner.run(link, in: workingDirectory, exitPolicy: .allowFailure)
        try? FileManager.default.removeItem(at: object)
        guard linked.succeeded else {
            throw HotReloadError(description: "could not link the patch: \(linked.errorOutput)")
        }
        return library
    }

    /// The driver's plan for the module, one frontend command per line. Planned again for every
    /// patch: with Xcode's compilation cache, the plan names snapshots of the sources as they are.
    private func frontendJobs(for module: SwiftModuleCommand) async throws -> [[String]] {
        let result = try await ProcessRunner.run(module.arguments + [Flag.printJobs], in: URL(fileURLWithPath: module.workingDirectory), exitPolicy: .allowFailure)
        guard result.succeeded else {
            throw HotReloadError(description: "could not plan \(module.module)'s compile: \(result.errorOutput)")
        }
        return result.output.split(whereSeparator: \.isNewline).map { ShellWords.split(String($0)) }
    }

    // MARK: Pure

    /// `job` compiling `primary` alone into `object`, or `nil` when it doesn't compile `primary`.
    /// Batch jobs compile several primary files: the others become plain inputs.
    static func patchJob(from job: [String], primary: URL, object: URL, workingDirectory: URL) -> [String]? {
        let wanted = Self.resolved(primary).path
        let base = URL(fileURLWithPath: workingDirectory.path, isDirectory: true)
        var arguments: [String] = []
        var compilesPrimary = false
        var index = job.startIndex

        while index < job.endIndex {
            let argument = job[index]
            let value = index + 1 < job.endIndex ? job[index + 1] : nil

            // Primary files: keep the changed one, demote the rest.
            if argument == Flag.primaryFile, let value {
                let isWanted = Self.resolved(URL(fileURLWithPath: value, relativeTo: base)).path == wanted
                compilesPrimary = compilesPrimary || isWanted
                arguments += isWanted ? [argument, value] : [value]
                index += 2
                continue
            }

            // Side outputs go, with their values.
            if Flag.sideOutputs.contains(argument) {
                index += 2
                continue
            }
            arguments.append(argument)
            index += 1
        }
        guard compilesPrimary else { return nil }
        return arguments + [Flag.output, object.path]
    }

    /// One spelling per file: `/tmp/x` and `/private/tmp/x` are the same file.
    public static func resolved(_ file: URL) -> URL {
        file.standardizedFileURL.resolvingSymlinksInPath()
    }
}
