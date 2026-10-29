import Foundation
import SwxApple
import SwxCore
import SwxDevice
import SwxSystem

/// `swx screenshot`: what the app looks like now, so an agent can check its own edits.
public enum Screenshots {
    private enum Layout {
        static let directory = "swx-screenshots"
        static let prefix = "screenshot-"
        static let fileExtension = "png"
        static let timestamp = "yyyyMMdd-HHmmss-SSS"
    }

    /// Where the screenshot was taken.
    public struct Shot: Sendable, Encodable {
        public let path: String
        public let target: String
    }

    /// Takes a screenshot of `device` (a simulator name or identifier), else of the hot reload
    /// session's app, else of the only booted simulator.
    public static func capture(packageDirectory: URL, device: String?, output: URL?, maxDimension: Int?) async throws -> Shot {
        let file = output ?? Self.defaultFile(in: packageDirectory)
        let target = try await Self.target(packageDirectory: packageDirectory, device: device)

        switch target {
        case .simulator(let simulator):
            try await DeviceRunner.screenshot(simulator: simulator.identifier, to: file)
        case .macApp(let pid):
            try await DeviceRunner.screenshot(macProcess: pid, to: file)
        }
        if let maxDimension {
            try await DeviceRunner.downscale(file, maxDimension: maxDimension)
        }
        return Shot(path: file.path, target: target.description)
    }

    private enum Target: CustomStringConvertible {
        case simulator(RunTarget)
        case macApp(pid: Int32)

        var description: String {
            switch self {
            case .simulator(let simulator):
                return "\(simulator.name) (\(simulator.identifier))"
            case .macApp(let pid):
                return "Mac app (pid \(pid))"
            }
        }
    }

    private static func target(packageDirectory: URL, device: String?) async throws -> Target {
        let simulators = try await DeviceRunner.simulators()

        // Asked for by name or identifier.
        if let device {
            guard let match = simulators.first(where: { $0.identifier == device || $0.name == device }) else {
                throw WorkspaceError(description: "no simulator named '\(device)'", code: .noScreenshotTarget, fix: "list simulators with `swx devices`")
            }
            return .simulator(match)
        }

        // The hot reload session's app.
        let session = HotSession(packageDirectory: packageDirectory)
        if let info = session.info(), ProcessControl.isRunning(info.pid) {
            if let identifier = info.device, let simulator = simulators.first(where: { $0.identifier == identifier }) {
                return .simulator(simulator)
            }
            if let pid = info.appProcess {
                return .macApp(pid: pid)
            }
        }

        // The one booted simulator.
        let booted = simulators.filter(\.isBooted)
        guard booted.count == 1, let only = booted.first else {
            let names = booted.map { "\($0.name) (\($0.identifier))" }.joined(separator: ", ")
            let problem = booted.isEmpty ? "no simulator is booted and no hot reload session is running" : "several simulators are booted: \(names)"
            throw WorkspaceError(description: problem, code: .noScreenshotTarget, fix: booted.isEmpty ? "swx hot start --platform ios <App>" : "pass --device <name or identifier>")
        }
        return .simulator(only)
    }

    private static func defaultFile(in packageDirectory: URL) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = Layout.timestamp
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return packageDirectory
            .appendingPathComponent(WellKnownFile.buildDirectory)
            .appendingPathComponent(Layout.directory)
            .appendingPathComponent(Layout.prefix + formatter.string(from: Date()))
            .appendingPathExtension(Layout.fileExtension)
    }
}
