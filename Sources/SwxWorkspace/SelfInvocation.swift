import Foundation
import SwxSystem

/// The JSON values the MCP server reads and writes.
public typealias JSONValue = SwxSystem.JSONValue

/// Runs this same swx binary as a child: background hot reload sessions and the MCP server's
/// tools are swx commands, so they can't drift from the CLI.
public enum SelfInvocation {
    /// What a child swx printed and how it ended.
    public struct Outcome: Sendable {
        public let output: String
        public let errors: String
        public let exitCode: Int32
        /// Stopped at the deadline.
        public let timedOut: Bool
    }

    /// The running swx binary.
    public static var executable: URL {
        ProcessControl.currentExecutable
    }

    /// Runs `swx <arguments>`, stopping it once `timeout` passes.
    public static func run(_ arguments: [String], timeout: Duration) async throws -> Outcome {
        let (result, timedOut) = try await ProcessRunner.run([Self.executable.path] + arguments, timeout: timeout)
        return Outcome(output: result.output, errors: result.errorOutput, exitCode: result.exitCode, timedOut: timedOut)
    }
}
