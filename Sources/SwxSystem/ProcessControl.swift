import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

/// Processes that outlive the command that started them, and signals to them.
public enum ProcessControl {
    private static let nullDevice = "/dev/null"
    private static let outputMode: mode_t = 0o644

    /// Starts `arguments` in a session of its own, detached from this terminal, with stdout and
    /// stderr appended to `output`: it keeps running after swx exits and isn't hit by the
    /// terminal's Ctrl-C. Returns its process identifier.
    public static func spawnDetached(_ arguments: [String], environment: [String: String], output: URL) throws -> Int32 {
        guard let executable = arguments.first else {
            throw SpawnError(executable: "", status: EINVAL)
        }

        // stdin from /dev/null; stdout and stderr to the log.
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, Self.nullDevice, O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, output.path, O_WRONLY | O_CREAT | O_APPEND, Self.outputMode)
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)

        // A new session: no controlling terminal, its own process group.
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        #if canImport(Darwin)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        #endif

        let cArguments = arguments.map { strdup($0) } + [nil]
        let cEnvironment = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            cArguments.forEach { free($0) }
            cEnvironment.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawnp(&pid, executable, &actions, &attributes, cArguments, cEnvironment)
        guard status == 0 else {
            throw SpawnError(executable: executable, status: status)
        }
        return pid
    }

    /// Whether a process with this identifier exists (and isn't a zombie of ours).
    public static func isRunning(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid {
            return false
        }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Asks a process to finish (SIGTERM).
    public static func terminate(_ pid: Int32) {
        kill(pid, SIGTERM)
    }

    /// Ends a process that didn't finish when asked (SIGKILL).
    public static func forceStop(_ pid: Int32) {
        kill(pid, SIGKILL)
    }

    /// This process's identifier.
    public static var currentIdentifier: Int32 {
        getpid()
    }

    /// The running swx binary, to start more of itself.
    public static var currentExecutable: URL {
        if let executable = Bundle.main.executableURL {
            return executable.resolvingSymlinksInPath()
        }
        let first = CommandLine.arguments.first ?? ""
        return first.contains("/") ? URL(fileURLWithPath: first).standardizedFileURL : (ExecutableLookup.find(first) ?? URL(fileURLWithPath: first))
    }

    /// Calls `handler` on the main queue when the process gets SIGTERM or SIGINT, instead of
    /// exiting. Children started afterwards still get the default handling.
    public static func onTermination(_ handler: @escaping @Sendable () -> Void) -> [AnyObject] {
        #if canImport(Darwin)
        return [SIGTERM, SIGINT].map { signalNumber in
            // A no-op handler (reset by exec) lets the dispatch source see the signal.
            signal(signalNumber) { _ in }
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler(handler: handler)
            source.resume()
            return source
        }
        #else
        return []
        #endif
    }
}

/// `posix_spawn` refused to start a program.
public struct SpawnError: Error, CustomStringConvertible {
    public let executable: String
    public let status: Int32

    public var description: String {
        "could not start \(self.executable): \(String(cString: strerror(self.status)))"
    }
}

extension ProcessRunner {
    /// Like `run`, but stops the process (SIGTERM) once `timeout` passes; `timedOut` says so.
    public static func run(_ arguments: [String], in directory: URL? = nil, timeout: Duration) async throws -> (result: ProcessResult, timedOut: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        let outputData = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
        let errorData = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }
        let timedOut = TimeoutFlag()
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
                return
            }

            // The deadline: stop it, and say so.
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(timeout.components.seconds * 1000))) {
                guard process.isRunning else { return }
                timedOut.set()
                process.terminate()
            }
        }
        let result = ProcessResult(exitCode: status, standardOutput: await outputData.value, standardError: await errorData.value)
        return (result, timedOut.isSet)
    }
}

/// Set once, read after: whether a deadline fired.
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        self.lock.lock()
        self.value = true
        self.lock.unlock()
    }

    var isSet: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.value
    }
}
