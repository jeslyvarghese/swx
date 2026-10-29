import Foundation
import SwxBuild
import SwxCore
import SwxSystem

/// What a hot reload run did, as it happened.
public enum HotEvent: Sendable {
    case building
    /// The build failed; swx waits for one of `watching` to change and builds again.
    case buildFailed(message: String, diagnostics: [BuildDiagnostic], log: URL?, watching: [URL])
    case launched(device: String?, deviceName: String?, appProcess: Int32?)
    /// The app runs, but without the agent (hardened runtime?).
    case agentMissing
    case watching(files: [URL])
    case reloaded(file: URL, functions: Int, seconds: Double)
    case notReloaded(file: URL, error: String)
    case relaunching(reason: String)
    case exited
    case stopped
}

extension HotEvent: CustomStringConvertible {
    private static let swiftExtension = "swift"

    public var description: String {
        switch self {
        case .building:
            return "building"
        case .buildFailed(let message, let diagnostics, _, _):
            let errors = diagnostics.filter { $0.severity == .error }.map(HotSession.describe)
            return ([message] + errors).joined(separator: "\n") + "\nwaiting for a change to build again"
        case .launched(_, let name, _):
            return "launched" + (name.map { " on \($0)" } ?? "")
        case .agentMissing:
            return "the app didn't load the hot reload agent (hardened runtime?); it runs without hot reload"
        case .watching(let files):
            let sources = files.filter { $0.pathExtension == Self.swiftExtension && $0.lastPathComponent != WellKnownFile.manifest }
            return "hot reload: watching \(sources.count) Swift files; saving one reloads it in the app"
        case .reloaded(let file, let functions, let seconds):
            return "reloaded \(file.lastPathComponent): \(functions) functions in \(String(format: "%.2f s", seconds))"
        case .notReloaded(let file, let error):
            return "\(file.lastPathComponent) not reloaded:\n\(error)"
        case .relaunching(let reason):
            return "\(reason): rebuilding and relaunching"
        case .exited:
            return "the app exited"
        case .stopped:
            return "stopped"
        }
    }
}

/// A hot reload run in the background (`swx hot start`), kept in files under `.build` so other
/// commands (`swx hot status|logs|stop`, `swx screenshot`) can find and follow it.
public struct HotSession: Sendable {
    /// The command a session runs, before the user's arguments.
    private static let runCommand = ["run", "--hot"]

    /// Set in the background run so it records its events.
    public static let environmentVariable = "SWX_HOT_SESSION"

    private enum Layout {
        static let directory = "hot-session"
        static let info = "session.json"
        static let events = "events.jsonl"
        static let output = "output.log"
    }

    /// What the run is and where it runs.
    public struct Info: Codable, Sendable {
        public var pid: Int32
        public var product: String
        public var platform: String
        public var startedAt: Date
        /// The simulator's identifier and name; `nil` on this Mac.
        public var device: String?
        public var deviceName: String?
        /// The app's process on this Mac.
        public var appProcess: Int32?
        /// The files whose saves the run reacts to.
        public var watchedFiles: [String]
    }

    public enum Kind: String, Codable, Sendable {
        case building
        case buildFailed = "build-failed"
        case launched
        case agentMissing = "agent-missing"
        case watching
        case reloaded
        case notReloaded = "not-reloaded"
        case relaunching
        case exited
        case stopped
    }

    public struct Event: Codable, Sendable {
        public let sequence: Int
        public let time: Date
        public let kind: Kind
        public let message: String
        public let file: String?
        public let seconds: Double?
        public let diagnostics: [BuildDiagnostic]?
    }

    /// Where the run is, from its last event.
    public enum Phase: String, Codable, Sendable {
        case starting
        case building
        case launching
        /// Watching for saves; edits reload into the app.
        case watching
        /// The app runs without the agent: saves change nothing.
        case runningWithoutReload = "running-without-reload"
        /// The build failed; the next save builds again.
        case waitingForFix = "waiting-for-fix"
        case exited
        case stopped
        /// The background run ended without saying why.
        case ended
        case notRunning = "not-running"
    }

    public struct Status: Encodable, Sendable {
        public let running: Bool
        public let phase: Phase
        public let product: String?
        public let platform: String?
        public let device: String?
        public let pid: Int32?
        public let startedAt: Date?
        public let events: [Event]
        /// The run's own output and the app's console.
        public let log: String
    }

    private let directory: URL

    public init(packageDirectory: URL) {
        self.directory = packageDirectory
            .appendingPathComponent(WellKnownFile.buildDirectory)
            .appendingPathComponent(AppleBuilds.stateDirectoryName)
            .appendingPathComponent(Layout.directory)
    }

    public var outputLog: URL {
        self.directory.appendingPathComponent(Layout.output)
    }

    private var infoFile: URL {
        self.directory.appendingPathComponent(Layout.info)
    }

    private var eventsFile: URL {
        self.directory.appendingPathComponent(Layout.events)
    }

    // MARK: Starting and stopping

    /// Starts `swx run --hot <arguments>` in the background as this package's session.
    public func start(_ arguments: [String], product: String, platform: String) throws -> Int32 {
        let command = [SelfInvocation.executable.path] + Self.runCommand + arguments
        if let info = self.info(), ProcessControl.isRunning(info.pid) {
            throw WorkspaceError(description: "a hot reload session for \(info.product) is already running (pid \(info.pid))", code: .hotSessionRunning, fix: "swx hot stop")
        }

        // A fresh directory: old events would read as this run's.
        try? FileManager.default.removeItem(at: self.directory)
        try FileSystem.createDirectory(self.directory)
        var environment = ProcessInfo.processInfo.environment
        environment[Self.environmentVariable] = self.directory.path
        let pid = try ProcessControl.spawnDetached(command, environment: environment, output: self.outputLog)
        try self.write(Info(pid: pid, product: product, platform: platform, startedAt: Date(), watchedFiles: []))
        return pid
    }

    /// Waits until the session has the app running and watched (or can't), then reports.
    public func waitForStartup(timeout: Duration) async -> Status {
        await self.wait(timeout: timeout, recent: Self.recentEvents) { status in
            ![.starting, .building, .launching].contains(status.phase)
        }
    }

    /// Waits until the session has dealt with every save made so far.
    public func waitUntilSettled(timeout: Duration, recent: Int = Self.recentEvents) async -> Status {
        await self.wait(timeout: timeout, recent: recent) { status in
            guard [.watching, .waitingForFix, .runningWithoutReload].contains(status.phase) else {
                return !status.running
            }

            // Every watched file older than the last event: nothing saved is still pending.
            let lastEvent = status.events.last?.time ?? .distantPast
            let watched = self.info()?.watchedFiles ?? []
            return watched.allSatisfy { (FileSystem.modificationDate(of: URL(fileURLWithPath: $0)) ?? .distantPast) <= lastEvent }
        }
    }

    private static let pollInterval = Duration.milliseconds(200)
    /// A save is seen within the watcher's interval and settling time; until then, an older
    /// last event can look current.
    private static let watcherLatency = Duration.milliseconds(500)

    private func wait(timeout: Duration, recent: Int, until done: (Status) -> Bool) async -> Status {
        let deadline = ContinuousClock.now + timeout
        try? await Task.sleep(for: Self.watcherLatency)
        while ContinuousClock.now < deadline {
            // At least the last event: settling compares against it.
            let status = self.status(recent: max(recent, 1))
            if done(status) {
                return status
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
        return self.status(recent: recent)
    }

    private static let stopTimeout = Duration.seconds(15)

    /// Asks the session to quit the app and end; ends it outright if it doesn't.
    public func stop() async throws -> Status {
        guard let info = self.info(), ProcessControl.isRunning(info.pid) else {
            throw WorkspaceError(description: "no hot reload session is running here", code: .noHotSession, fix: "swx hot start --platform ios <App>")
        }
        ProcessControl.terminate(info.pid)
        let deadline = ContinuousClock.now + Self.stopTimeout
        while ProcessControl.isRunning(info.pid), ContinuousClock.now < deadline {
            try? await Task.sleep(for: Self.pollInterval)
        }
        if ProcessControl.isRunning(info.pid) {
            ProcessControl.forceStop(info.pid)
            self.record(.stopped)
        }
        return self.status()
    }

    // MARK: Reading

    public func info() -> Info? {
        FileSystem.readIfPresent(self.infoFile).flatMap { try? Self.decoder.decode(Info.self, from: $0) }
    }

    public func events() -> [Event] {
        let text = String(decoding: FileSystem.readIfPresent(self.eventsFile) ?? Data(), as: UTF8.self)
        return text.split(separator: "\n").compactMap { try? Self.decoder.decode(Event.self, from: Data($0.utf8)) }
    }

    public static let recentEvents = 10

    public func status(recent: Int = Self.recentEvents) -> Status {
        guard let info = self.info() else {
            return Status(running: false, phase: .notRunning, product: nil, platform: nil, device: nil, pid: nil, startedAt: nil, events: [], log: self.outputLog.path)
        }
        let events = self.events()
        let running = ProcessControl.isRunning(info.pid)
        return Status(
            running: running,
            phase: Self.phase(after: events.last?.kind, running: running),
            product: info.product,
            platform: info.platform,
            device: info.deviceName ?? info.device,
            pid: info.pid,
            startedAt: info.startedAt,
            events: Array(events.suffix(recent)),
            log: self.outputLog.path
        )
    }

    public static func phase(after kind: Kind?, running: Bool) -> Phase {
        switch kind {
        case nil:
            return running ? .starting : .ended
        case .exited:
            return .exited
        case .stopped:
            return .stopped
        case _ where !running:
            return .ended
        case .building?, .relaunching?:
            return .building
        case .launched?:
            return .launching
        case .buildFailed?:
            return .waitingForFix
        case .agentMissing?:
            return .runningWithoutReload
        case .watching?, .reloaded?, .notReloaded?:
            return .watching
        }
    }

    /// The last `count` lines of the session's output (all of it for `nil`).
    public func outputLines(last count: Int?) -> [String] {
        let text = String(decoding: FileSystem.readIfPresent(self.outputLog) ?? Data(), as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { BuildLog.removingEscapes(String($0)) }
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        guard let count else { return lines }
        return Array(lines.suffix(count))
    }

    // MARK: Recording (in the background run)

    /// The session this process records into, when it is one.
    public static var current: HotSession? {
        guard let path = ProcessInfo.processInfo.environment[Self.environmentVariable] else { return nil }
        return HotSession(directory: URL(fileURLWithPath: path))
    }

    private init(directory: URL) {
        self.directory = directory
    }

    /// Appends the event, and keeps the session's facts (device, watched files) current.
    public func record(_ event: HotEvent) {
        var info = self.info()
        switch event {
        case .launched(let device, let deviceName, let appProcess):
            info?.device = device
            info?.deviceName = deviceName
            info?.appProcess = appProcess
        case .watching(let files), .buildFailed(_, _, _, let files):
            info?.watchedFiles = files.map(\.path)
        default:
            break
        }
        if let info {
            try? self.write(info)
        }

        let entry = Self.entry(for: event, sequence: self.events().count + 1)
        guard var line = try? Self.encoder.encode(entry) else { return }
        line.append(UInt8(ascii: "\n"))
        Self.append(line, to: self.eventsFile)
    }

    private static func entry(for event: HotEvent, sequence: Int) -> Event {
        let time = Date()
        func make(_ kind: Kind, file: URL? = nil, seconds: Double? = nil, diagnostics: [BuildDiagnostic]? = nil) -> Event {
            Event(sequence: sequence, time: time, kind: kind, message: event.description, file: file?.path, seconds: seconds, diagnostics: diagnostics)
        }
        switch event {
        case .building:
            return make(.building)
        case .buildFailed(_, let diagnostics, _, _):
            return make(.buildFailed, diagnostics: diagnostics)
        case .launched:
            return make(.launched)
        case .agentMissing:
            return make(.agentMissing)
        case .watching:
            return make(.watching)
        case .reloaded(let file, _, let seconds):
            return make(.reloaded, file: file, seconds: seconds)
        case .notReloaded(let file, let error):
            return make(.notReloaded, file: file, diagnostics: BuildLog.diagnostics(in: error))
        case .relaunching:
            return make(.relaunching)
        case .exited:
            return make(.exited)
        case .stopped:
            return make(.stopped)
        }
    }

    private func write(_ info: Info) throws {
        try FileSystem.writeAtomically(try Self.encoder.encode(info), to: self.infoFile)
    }

    private static func append(_ data: Data, to file: URL) {
        guard let handle = FileHandle(forWritingAtPath: file.path) else {
            try? data.write(to: file)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Fractional seconds: settling compares event times with file modification times.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.timestampFormatter.string(from: date))
        }
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = Self.timestampFormatter.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a timestamp: \(text)"))
            }
            return date
        }
        return decoder
    }

    private static var timestampFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    /// `File.swift:3:7: message` for a diagnostic.
    static func describe(_ diagnostic: BuildDiagnostic) -> String {
        guard let file = diagnostic.file else { return "\(diagnostic.severity.rawValue): \(diagnostic.message)" }
        return "\(file):\(diagnostic.line ?? 0):\(diagnostic.column ?? 0): \(diagnostic.severity.rawValue): \(diagnostic.message)"
    }
}
