import Foundation
import SwxSystem
#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

/// swx's end of the conversation with the agent: a TCP socket on the loopback interface. The
/// agent connects once it's loaded; swx sends one patch path per line and reads one reply per
/// line. TCP rather than a signal or a Unix socket, so a device can use the same protocol later.
public final class AgentChannel: @unchecked Sendable {
    /// What the agent did with a patch.
    public enum Reply: Sendable {
        /// The patch runs: `functions` of it replaced the app's, through `references` (call
        /// slots, vtable and witness entries) now pointing at it.
        case loaded(functions: Int, references: Int)
        /// The patch can't run in this process: `reason` says why.
        case needsRelaunch(reason: String)
    }

    private enum Wire {
        static let success = "ok"
        static let failure = "error"
        static let relaunch = "relaunch"
        static let newline = UInt8(ascii: "\n")
        static let backlog: Int32 = 1
    }

    public let port: Int
    private let listener: Int32
    private var connection: Int32 = -1
    /// Socket calls block, so they run here, one at a time, off the cooperative pool.
    private let queue = DispatchQueue(label: "swx.hot-reload.agent")

    private init(listener: Int32, port: Int) {
        self.listener = listener
        self.port = port
    }

    deinit {
        if self.connection >= 0 { close(self.connection) }
        close(self.listener)
    }

    #if canImport(Darwin)
    /// Listens on 127.0.0.1, on a port the system picks.
    public static func listen() throws -> AgentChannel {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Self.error("socket") }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { general in
                bind(listener, general, length) == 0 && Darwin.listen(listener, Wire.backlog) == 0
                    && getsockname(listener, general, &length) == 0
            }
        }
        guard bound else {
            close(listener)
            throw Self.error("listen")
        }
        return AgentChannel(listener: listener, port: Int(UInt16(bigEndian: address.sin_port)))
    }

    /// Waits for the agent to connect; `false` when it didn't within `timeout`.
    public func accept(timeout: Duration) async -> Bool {
        let milliseconds = Int32(timeout.components.seconds * 1000)
        return await self.onQueue { () -> Bool in
            var request = pollfd(fd: self.listener, events: Int16(POLLIN), revents: 0)
            guard poll(&request, 1, milliseconds) > 0 else { return false }
            self.connection = Darwin.accept(self.listener, nil, nil)
            return self.connection >= 0
        }
    }

    /// Hands the agent a patch and waits for its answer.
    public func load(_ patch: URL) async throws -> Reply {
        let line = try await self.onQueue { () throws -> String in
            let request = Array((patch.path + "\n").utf8)
            guard request.withUnsafeBytes({ send(self.connection, $0.baseAddress, $0.count, 0) }) == request.count else {
                throw Self.error("send")
            }
            return try self.readLine()
        }

        // "ok <functions> <references>", "relaunch <symbol>" or "error <reason>".
        let fields = line.split(separator: " ", maxSplits: 2).map(String.init)
        if fields.first == Wire.relaunch, fields.count == 2 {
            return .needsRelaunch(reason: await Self.describe(changedOpaqueType: fields[1]))
        }
        guard fields.first == Wire.success, fields.count == 3, let functions = Int(fields[1]), let references = Int(fields[2]) else {
            let reason = fields.first == Wire.failure ? line.dropFirst(Wire.failure.count + 1) : Substring(line)
            throw HotReloadError(description: "the app could not load the patch: \(reason)")
        }
        return .loaded(functions: functions, references: references)
    }

    /// `$s3Hot11ContentViewV4bodyQrvpQOMQ` → "ContentView.body returns another type of view".
    private static func describe(changedOpaqueType symbol: String) async -> String {
        let demangled = (try? await ProcessRunner.run(["xcrun", "swift-demangle", "--simplified", "--compact", symbol]))?.output ?? ""
        guard let start = demangled.range(of: Demangled.opaqueReturnPrefix),
              let end = demangled.range(of: Demangled.opaqueReturnSuffix, range: start.upperBound..<demangled.endIndex) else {
            return "an opaque result type (\(symbol)) now stands for another type"
        }
        return "\(demangled[start.upperBound..<end.lowerBound]) now returns another type"
    }

    private enum Demangled {
        static let opaqueReturnPrefix = "opaque return type of "
        static let opaqueReturnSuffix = ">>"
    }

    private func readLine() throws -> String {
        // Replies are short: reading a byte at a time keeps nothing past the newline.
        var line: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            guard recv(self.connection, &byte, 1, 0) == 1 else {
                throw HotReloadError(description: "the app closed the hot reload connection")
            }
            if byte == Wire.newline {
                return String(decoding: line, as: UTF8.self)
            }
            line.append(byte)
        }
    }
    #else
    public static func listen() throws -> AgentChannel {
        throw HotReloadError(description: "hot reload needs macOS")
    }

    public func accept(timeout: Duration) async -> Bool {
        false
    }

    public func load(_ patch: URL) async throws -> Reply {
        throw HotReloadError(description: "hot reload needs macOS")
    }
    #endif

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            self.queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            self.queue.async {
                continuation.resume(returning: work())
            }
        }
    }

    private static func error(_ call: String) -> HotReloadError {
        HotReloadError(description: "\(call) failed: \(String(cString: strerror(errno)))")
    }
}
