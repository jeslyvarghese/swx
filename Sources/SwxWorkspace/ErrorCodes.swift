import Foundation
import SwxBuild
import SwxDevice
import SwxHotReload
import SwxSystem

/// Stable names for failures, as `--format json` reports them: tools match on these, not on
/// the wording of the message.
public enum ErrorCode: String, Sendable, Codable {
    case unknownPlatform = "unknown-platform"
    case unknownDestination = "unknown-destination"
    case missingProduct = "missing-product"
    case noAppBundle = "no-app-bundle"
    case unsupportedDestination = "unsupported-destination"
    case hotSessionRunning = "hot-session-running"
    case noHotSession = "no-hot-session"
    case noScreenshotTarget = "no-screenshot-target"
    case lockfileMissing = "lockfile-missing"
    case lockfileStale = "lockfile-stale"
    case unsupportedOption = "unsupported-option"
    case buildFailed = "build-failed"
    case device = "device"
    case hotReload = "hot-reload"
    case subprocess = "subprocess"
    case usage = "usage"
    case failed = "failed"
}

/// Any error swx can throw, as a code, a message and, where one is known, a fix.
public struct ErrorSummary: Sendable, Codable {
    public let code: ErrorCode
    public let message: String
    public let fix: String?

    public init(code: ErrorCode, message: String, fix: String? = nil) {
        self.code = code
        self.message = message
        self.fix = fix
    }

    public init(_ error: Error) {
        switch error {
        case let error as WorkspaceError:
            self.init(code: error.code ?? .failed, message: error.description, fix: error.fix)
        case let error as BuildError:
            self.init(code: .buildFailed, message: error.description, fix: error.log.map { "read the log: \($0.path)" })
        case let error as DeviceError:
            self.init(code: .device, message: error.description, fix: error.fix ?? "list simulators and devices with `swx devices`")
        case let error as HotReloadError:
            self.init(code: .hotReload, message: error.description)
        case let error as ProcessError:
            self.init(code: .subprocess, message: error.description)
        default:
            self.init(code: .failed, message: String(describing: error))
        }
    }
}
