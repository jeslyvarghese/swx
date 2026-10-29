import Foundation
import SwxApple
import SwxSystem

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Screenshots of simulators and of Mac app windows, and launches that return right away.
extension DeviceRunner {
    private enum Tool {
        static let xcrun = "xcrun"
        static let screencapture = "/usr/sbin/screencapture"
        static let sips = "/usr/bin/sips"
    }

    /// Writes a PNG of the simulator's screen.
    public static func screenshot(simulator identifier: String, to file: URL) async throws {
        try FileSystem.createDirectory(file.deletingLastPathComponent())
        let result = try await ProcessRunner.run([Tool.xcrun, "simctl", "io", identifier, "screenshot", "--type=png", file.path], exitPolicy: .allowFailure)
        guard result.succeeded else {
            throw DeviceError(description: "could not take a screenshot of simulator \(identifier): \(result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// Writes a PNG of the frontmost window of a Mac app (needs Screen Recording permission for
    /// the terminal running swx).
    public static func screenshot(macProcess pid: Int32, to file: URL) async throws {
        guard let window = Self.window(of: pid) else {
            throw DeviceError(description: "process \(pid) has no window on screen")
        }
        try FileSystem.createDirectory(file.deletingLastPathComponent())
        let result = try await ProcessRunner.run([Tool.screencapture, "-x", "-o", "-l\(window)", file.path], exitPolicy: .allowFailure)
        guard result.succeeded, FileSystem.exists(file) else {
            throw DeviceError(
                description: "could not capture the app's window: \(result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))",
                fix: "allow Screen Recording for the app running swx (System Settings → Privacy & Security → Screen & System Audio Recording), then restart it"
            )
        }
    }

    /// Scales an image down so its longer side is at most `maxDimension` pixels.
    public static func downscale(_ image: URL, maxDimension: Int) async throws {
        try await ProcessRunner.run([Tool.sips, "-Z", String(maxDimension), image.path])
    }

    /// The window to capture: the app's largest on-screen window at the normal level.
    private static func window(of pid: Int32) -> UInt32? {
        #if canImport(CoreGraphics)
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        let owned = windows.filter {
            ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        func area(_ window: [String: Any]) -> Double {
            let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
            return (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
        }
        return owned.max { area($0) < area($1) }.flatMap { $0[kCGWindowNumber as String] as? UInt32 }
        #else
        return nil
        #endif
    }

    /// Installs and launches an app on a simulator without attaching to its console; returns
    /// once it is running.
    public static func launchInBackground(app: URL, bundleIdentifier: String, on target: RunTarget, arguments: [String]) async throws {
        guard target.environment == .simulator else {
            throw DeviceError(description: "\(target.name) is a device; this launches on simulators")
        }
        try await Self.bootAndInstall(app: app, on: target)
        try await ProcessRunner.run([Tool.xcrun, "simctl", "launch", "--terminate-running-process", target.identifier, bundleIdentifier] + arguments)
    }
}
