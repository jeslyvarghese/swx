import Foundation
import SwxSystem

/// How one Swift module was compiled: the `swiftc` driver invocation a build ran for it. Hot
/// reload recompiles single files with exactly these flags.
///
/// Today these come from xcodebuild's log; a build driver that plans builds itself can hand
/// them over directly.
public struct SwiftModuleCommand: Sendable, Codable, Hashable {
    public let module: String
    public let architecture: String
    /// `swiftc` and its arguments.
    public let arguments: [String]
    public let workingDirectory: String

    private enum Flag {
        static let target = "-target"
        static let sdk = "-sdk"
        static let workingDirectory = "-working-directory"
        static let responseFilePrefix = "@"
        static let swiftExtension = ".swift"
    }

    public init(module: String, architecture: String, arguments: [String], workingDirectory: String) {
        self.module = module
        self.architecture = architecture
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }

    /// `arm64-apple-ios17.0-simulator`.
    public var target: String? {
        self.value(of: Flag.target)
    }

    public var sdk: String? {
        self.value(of: Flag.sdk)
    }

    /// The module's Swift files, resolved (`/tmp` → `/private/tmp`): listed directly or in a
    /// file list (`@…SwiftFileList`, one path per line, as Xcode passes them).
    public func sourceFiles() -> [URL] {
        let base = URL(fileURLWithPath: self.value(of: Flag.workingDirectory) ?? self.workingDirectory, isDirectory: true)
        var paths: [String] = []
        for argument in self.arguments.dropFirst() {
            if argument.hasPrefix(Flag.responseFilePrefix) {
                let list = String(argument.dropFirst(Flag.responseFilePrefix.count))
                let contents = FileSystem.readIfPresent(URL(fileURLWithPath: list)).map { String(decoding: $0, as: UTF8.self) } ?? ""
                paths += contents.split(whereSeparator: \.isNewline).flatMap { ShellWords.split(String($0)) }
                continue
            }
            if argument.hasSuffix(Flag.swiftExtension) {
                paths.append(argument)
            }
        }
        return paths
            .filter { $0.hasSuffix(Flag.swiftExtension) }
            .map { URL(fileURLWithPath: $0, relativeTo: base).standardizedFileURL.resolvingSymlinksInPath() }
    }

    private func value(of flag: String) -> String? {
        guard let index = self.arguments.firstIndex(of: flag), index + 1 < self.arguments.count else { return nil }
        return self.arguments[index + 1]
    }
}

/// Reads the per-module `swiftc` invocations out of xcodebuild's full (non-`-quiet`) log.
///
/// Each module's compile shows up as
/// ```
/// SwiftDriver Hot normal arm64 com.apple.xcode.tools.swift.compiler (in target 'Hot' from project 'Hot')
///     cd /path/to/project
///     builtin-SwiftDriver -- /…/swiftc -module-name Hot …
/// ```
public enum XcodeBuildLog {
    private enum Marker {
        static let task = "SwiftDriver "
        static let changeDirectory = "cd "
        static let driver = "builtin-SwiftDriver -- "
        /// `SwiftDriver <module> <variant> <arch> …`
        static let moduleField = 1
        static let architectureField = 3
    }

    public static func swiftModuleCommands(in log: String) -> [SwiftModuleCommand] {
        var commands: [SwiftModuleCommand] = []
        var module: (name: String, architecture: String)?
        var directory = ""

        for rawLine in log.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Unindented lines start tasks; only a module's driver task starts a block to read…
            if let first = rawLine.first, !first.isWhitespace {
                let fields = rawLine.split(separator: " ")
                let isDriverTask = rawLine.hasPrefix(Marker.task) && fields.count > Marker.architectureField
                module = isDriverTask ? (String(fields[Marker.moduleField]), String(fields[Marker.architectureField])) : nil
                directory = ""
                continue
            }
            guard let current = module else { continue }

            // …that names its directory and then the driver command.
            if line.hasPrefix(Marker.changeDirectory) {
                directory = ShellWords.split(String(line.dropFirst(Marker.changeDirectory.count))).first ?? ""
                continue
            }
            guard let range = line.range(of: Marker.driver) else { continue }
            commands.append(SwiftModuleCommand(
                module: current.name,
                architecture: current.architecture,
                arguments: ShellWords.split(String(line[range.upperBound...])),
                workingDirectory: directory
            ))
            module = nil
        }
        return commands
    }
}

/// The latest command of every module, kept next to the build: an incremental build that
/// didn't recompile a module doesn't log its command again.
struct SwiftModuleCommandStore {
    private static let file = "swx-swift-commands.json"

    private let file: URL

    init(derivedData: URL) {
        self.file = derivedData.appendingPathComponent(Self.file)
    }

    /// Records the commands of this build over the remembered ones; returns them all.
    func merge(_ commands: [SwiftModuleCommand]) -> [SwiftModuleCommand] {
        let remembered = FileSystem.readIfPresent(self.file).flatMap { try? JSONDecoder().decode([SwiftModuleCommand].self, from: $0) } ?? []

        // A module is one module name per architecture.
        var byModule: [String: SwiftModuleCommand] = [:]
        for command in remembered + commands {
            byModule[command.module + " " + command.architecture] = command
        }
        let merged = byModule.keys.sorted().compactMap { byModule[$0] }
        if let data = try? JSONEncoder().encode(merged) {
            try? FileSystem.writeAtomically(data, to: self.file)
        }
        return merged
    }
}
