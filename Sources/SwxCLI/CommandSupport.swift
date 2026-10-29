import ArgumentParser
import Foundation
import SwxWorkspace

/// Shared plumbing for commands.
enum CommandSupport {
    /// Activates the toolchain requested by `.swift-version`, installing it if needed.
    static func prepareToolchain(for global: GlobalOptions) async throws {
        try await Self.reportingErrors {
            try await Toolchains().prepare(for: global.packageURL, missing: .install) { Self.status($0) }
        }
    }

    /// Prints the error SwiftPM-style and exits with failure instead of a stack of descriptions.
    @discardableResult
    static func reportingErrors<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let exit as ExitCode {
            throw exit
        } catch {
            Self.report(error)
            throw ExitCode.failure
        }
    }

    @discardableResult
    static func reportingErrors<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch let exit as ExitCode {
            throw exit
        } catch {
            Self.report(error)
            throw ExitCode.failure
        }
    }

    /// An error as `error: …` on stderr, or as a JSON object on stdout with `--format json`.
    static func report(_ error: Error) {
        guard OutputFormat.active == .json else {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return
        }
        JSONOutput.printError(error)
    }

    /// Progress goes to stderr so stdout stays clean for tools and scripts.
    static func status(_ message: String) {
        FileHandle.standardError.write(Data("[swx] \(message)\n".utf8))
    }
}
