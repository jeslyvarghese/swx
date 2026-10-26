import Foundation

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

/// The captured result of a finished subprocess.
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: Data

    public var output: String {
        String(decoding: self.standardOutput, as: UTF8.self)
    }

    public var errorOutput: String {
        String(decoding: self.standardError, as: UTF8.self)
    }

    public var succeeded: Bool {
        self.exitCode == 0
    }
}

public struct ProcessError: Error, CustomStringConvertible {
    public let command: [String]
    public let result: ProcessResult

    public var description: String {
        let stderr = self.result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return "`\(self.command.joined(separator: " "))` failed (exit \(self.result.exitCode)): \(stderr)"
    }
}

/// Whether a non-zero exit status should throw.
public enum ExitPolicy: Sendable {
    case requireSuccess
    case allowFailure
}

/// Runs subprocesses without blocking the cooperative thread pool.
public enum ProcessRunner {
    private static let environmentLauncher = "/usr/bin/env"

    /// Runs `arguments[0]` (looked up on `PATH`) with the remaining arguments.
    @discardableResult
    public static func run(
        _ arguments: [String],
        in directory: URL? = nil,
        environment: [String: String]? = nil,
        input: Data? = nil,
        exitPolicy: ExitPolicy = .requireSuccess
    ) async throws -> ProcessResult {
        Trace.event("spawn \(arguments.prefix(4).joined(separator: " "))")
        let result = try await Self.launch(arguments, in: directory, environment: environment, input: input)
        Trace.event("exit  \(arguments.prefix(4).joined(separator: " ")) → \(result.exitCode)")
        if exitPolicy == .requireSuccess && !result.succeeded {
            throw ProcessError(command: arguments, result: result)
        }
        return result
    }

    private static func launch(
        _ arguments: [String],
        in directory: URL?,
        environment: [String: String]?,
        input: Data?
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.environmentLauncher)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let inputPipe = input.map { _ in Pipe() }
        process.standardInput = inputPipe ?? FileHandle.nullDevice

        // Drain both pipes from the start, each on its own thread, so a chatty child can't block on
        // a full buffer. Each reader reads its pipe front to back, so output stays in order.
        let output = Self.readToEnd(outputPipe.fileHandleForReading)
        let errors = Self.readToEnd(errorPipe.fileHandleForReading)

        // Resume when the process exits.
        let exitCode: Int32
        do {
            exitCode = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                    return
                }

                // Feed stdin from a background thread, then close it so the child sees EOF.
                guard let input, let inputPipe else { return }
                let writer = inputPipe.fileHandleForWriting
                DispatchQueue.global().async {
                    try? writer.write(contentsOf: input)
                    try? writer.close()
                }
            }
        } catch {
            // Nothing will write to the pipes: close them so the readers finish.
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()
            _ = await (output.value, errors.value)
            throw error
        }

        return ProcessResult(exitCode: exitCode, standardOutput: await output.value, standardError: await errors.value)
    }

    /// Reads `handle` to end-of-file on a background thread.
    private static func readToEnd(_ handle: FileHandle) -> Task<Data, Never> {
        Task {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: handle.readDataToEndOfFile())
                }
            }
        }
    }

    /// Runs a command with this process's stdin/stdout/stderr, returning its exit status.
    public static func runStreaming(_ arguments: [String], in directory: URL? = nil) async throws -> Int32 {
        Trace.event("stream \(arguments.prefix(4).joined(separator: " "))")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.environmentLauncher)
        process.arguments = arguments
        process.currentDirectoryURL = directory

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// Replaces the current process image (used for pass-through commands).
    public static func exec(_ arguments: [String]) -> Never {
        let cArguments = arguments.map { strdup($0) } + [nil]
        execvp(arguments[0], cArguments)
        perror("swx: exec \(arguments[0])")
        exit(EXIT_FAILURE)
    }
}

/// Caps how many subprocesses run at once (git and swiftc are CPU- and fd-hungry).
public actor ConcurrencyLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await self.acquire()
        defer { self.release() }
        return try await operation()
    }

    private func acquire() async {
        guard self.running >= self.limit else {
            self.running += 1
            return
        }
        await withCheckedContinuation { self.waiters.append($0) }
    }

    private func release() {
        guard !self.waiters.isEmpty else {
            self.running -= 1
            return
        }
        // Hand the slot straight to the next waiter.
        self.waiters.removeFirst().resume()
    }
}
