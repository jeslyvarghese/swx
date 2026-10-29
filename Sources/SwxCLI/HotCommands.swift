import ArgumentParser
import Foundation
import SwxWorkspace

/// `swx hot …`: hot reload in the background, for agents and editors that can't sit in a
/// terminal: start it, check what the last save did, read the app's output, stop it.
struct HotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hot",
        abstract: "Run an app with hot reload in the background, and follow it.",
        subcommands: [HotStart.self, HotStatus.self, HotLogs.self, HotStop.self]
    )
}

/// `swx hot start --platform ios App`: builds, launches and watches in the background; returns
/// once the app runs (or the build failed).
struct HotStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start `swx run --hot` in the background; returns once the app is running and watched."
    )

    @Argument(parsing: .captureForPassthrough, help: "--platform ios|tvos|watchos|visionos|macos [--device NAME] [--package-path P] [--timeout SECONDS] <App> [app arguments], as for `swx run --hot`.")
    var arguments: [String] = []

    /// A first build can take minutes (dependencies, XcodeGen).
    static let defaultTimeout = Duration.seconds(1200)

    func run() async throws {
        var arguments = self.arguments
        let format = OutputFormat.take(from: &arguments)
        let timeout = HotStatus.takeSeconds(Run.timeoutOption, from: &arguments) ?? Self.defaultTimeout
        try await Self.start(arguments, format: format, timeout: timeout)
    }

    /// Starts `swx run --hot <arguments>` as the package's session and reports once it's up.
    static func start(_ arguments: [String], format: OutputFormat, timeout: Duration) async throws -> Never {
        var probe = arguments
        guard let apple = AppleArguments.extract(from: &probe) else {
            try await CommandSupport.reportingErrors {
                throw WorkspaceError(description: "hot reload needs a platform", code: .usage, fix: "swx hot start --platform ios <App>")
            }
            throw ExitCode.failure
        }
        guard let product = probe.first(where: { !$0.hasPrefix("-") }) ?? apple.product else {
            try await AppleArguments.missingProduct(platform: apple.target.platform)
        }

        // The background run is this same binary, in a session of its own.
        let session = HotSession(packageDirectory: apple.packageDirectory)
        try CommandSupport.reportingErrors {
            _ = try session.start(arguments, product: product, platform: apple.target.platform)
        }
        CommandSupport.status("building and launching \(product) in the background; output: \(session.outputLog.path)")

        let status = await session.waitForStartup(timeout: timeout)
        HotStatus.print(status, format: format)
        throw [.watching, .runningWithoutReload].contains(status.phase) ? ExitCode.success : ExitCode.failure
    }
}

/// `swx hot status [--wait]`: what the session is doing and what the last saves did.
struct HotStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the hot reload session: running or not, and its latest events (reloads, compile errors, relaunches)."
    )

    @Option(name: .customLong("package-path"), help: "The package (or project directory) the session runs.")
    var packagePath: String = "."

    @Flag(help: "Wait until every save so far was reloaded, failed or relaunched (call it right after editing).")
    var wait = false

    @Option(help: "How long --wait waits, in seconds.")
    var timeout: Double = 600

    @Option(help: "How many recent events to show.")
    var events: Int = HotSession.recentEvents

    @Option(help: "text or json (default: $SWX_FORMAT, else text).")
    var format: OutputFormat = .preferred

    func run() async throws {
        let session = HotSession(packageDirectory: FileSystemPaths.absolute(self.packagePath))
        let status = self.wait
            ? await session.waitUntilSettled(timeout: .milliseconds(Int(self.timeout * 1000)), recent: self.events)
            : session.status(recent: self.events)
        Self.print(status, format: self.format)
        guard status.phase != .notRunning else { throw ExitCode.failure }
    }

    private static let timeFormat = "HH:mm:ss"

    static func print(_ status: HotSession.Status, format: OutputFormat) {
        guard format == .text else {
            JSONOutput.print(status)
            return
        }

        // `hot reload: watching (App on iPhone 17, pid 42)`, then the events, then the log.
        let formatter = DateFormatter()
        formatter.dateFormat = Self.timeFormat
        let what = [status.product, status.device.map { "on \($0)" }, status.pid.map { "pid \($0)" }].compactMap { $0 }.joined(separator: ", ")
        Swift.print("hot reload: \(status.phase.rawValue)" + (what.isEmpty ? "" : " (\(what))"))
        for event in status.events {
            Swift.print("  \(formatter.string(from: event.time)) \(event.message.replacingOccurrences(of: "\n", with: "\n    "))")
        }
        Swift.print("log: \(status.log)")
    }

    /// `--name SECONDS` among passed-through arguments.
    static func takeSeconds(_ option: String, from arguments: inout [String]) -> Duration? {
        guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count, let seconds = Double(arguments[index + 1]) else {
            return nil
        }
        arguments.removeSubrange(index...(index + 1))
        return .milliseconds(Int(seconds * 1000))
    }
}

/// `swx hot logs`: the app's console and swx's messages, from the session's log.
struct HotLogs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "logs", abstract: "Print the hot reload session's output: the app's console and swx's messages.")

    @Option(name: .customLong("package-path"), help: "The package (or project directory) the session runs.")
    var packagePath: String = "."

    @Option(help: "How many of the last lines to print.")
    var lines: Int = 100

    @Flag(help: "Print the whole log.")
    var all = false

    @Option(help: "text or json (default: $SWX_FORMAT, else text).")
    var format: OutputFormat = .preferred

    private struct Report: Encodable {
        let lines: [String]
        let log: String
    }

    func run() async throws {
        let session = HotSession(packageDirectory: FileSystemPaths.absolute(self.packagePath))
        let lines = session.outputLines(last: self.all ? nil : self.lines)
        guard self.format == .text else {
            JSONOutput.print(Report(lines: lines, log: session.outputLog.path))
            return
        }
        Swift.print(lines.joined(separator: "\n"))
    }
}

/// `swx hot stop`: quits the app and ends the session.
struct HotStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Quit the app and end the hot reload session.")

    @Option(name: .customLong("package-path"), help: "The package (or project directory) the session runs.")
    var packagePath: String = "."

    @Option(help: "text or json (default: $SWX_FORMAT, else text).")
    var format: OutputFormat = .preferred

    func run() async throws {
        let session = HotSession(packageDirectory: FileSystemPaths.absolute(self.packagePath))
        let status = try await CommandSupport.reportingErrors { try await session.stop() }
        HotStatus.print(status, format: self.format)
    }
}

/// `swx screenshot`: a PNG of the simulator (or Mac app) the app runs in.
struct Screenshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Save a screenshot of the hot reload session's app, a named simulator, or the only booted one; prints the PNG's path."
    )

    @Option(name: .customLong("package-path"), help: "The package whose hot reload session to look at.")
    var packagePath: String = "."

    @Option(help: "A simulator name or identifier.")
    var device: String?

    @Option(help: "Where to write the PNG (default: .build/swx-screenshots/).")
    var output: String?

    @Option(help: "Scale down so the longer side is at most this many pixels.")
    var maxDimension: Int?

    @Option(help: "text or json (default: $SWX_FORMAT, else text).")
    var format: OutputFormat = .preferred

    func run() async throws {
        let shot = try await CommandSupport.reportingErrors {
            try await Screenshots.capture(
                packageDirectory: FileSystemPaths.absolute(self.packagePath),
                device: self.device,
                output: self.output.map(FileSystemPaths.absolute),
                maxDimension: self.maxDimension
            )
        }
        guard self.format == .text else {
            JSONOutput.print(shot)
            return
        }
        print(shot.path)
    }
}
