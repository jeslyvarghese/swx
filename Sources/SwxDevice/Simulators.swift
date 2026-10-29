import Foundation
import SwxApple
import SwxSystem

/// A simulator or a connected device.
public struct RunTarget: Sendable, Hashable {
    public let identifier: String
    public let name: String
    public let platform: ApplePlatform
    public let environment: AppleEnvironment
    /// `27.0` for simulators; the OS version for devices when known.
    public let osVersion: String
    public let isBooted: Bool
}

public struct DeviceError: Error, CustomStringConvertible {
    public let description: String
}

/// Lists, boots and drives simulators (`simctl`) and devices (`devicectl`).
///
/// The only module that launches anything on a simulator or device.
public enum DeviceRunner {
    private enum Simctl {
        static let runtimePrefix = "com.apple.CoreSimulator.SimRuntime."
        static let booted = "Booted"
        static let alreadyBootedStatus: Int32 = 149
    }

    private static let xcrun = "xcrun"

    // MARK: Listing

    public static func simulators() async throws -> [RunTarget] {
        let result = try await ProcessRunner.run([Self.xcrun, "simctl", "list", "devices", "available", "-j"])
        guard let json = try JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]] else {
            throw DeviceError(description: "unexpected `simctl list` output")
        }

        var targets: [RunTarget] = []
        for (runtime, entries) in devices {
            guard let (platform, version) = Self.parseRuntime(runtime) else { continue }
            for entry in entries {
                guard let udid = entry["udid"] as? String, let name = entry["name"] as? String else { continue }
                targets.append(RunTarget(
                    identifier: udid,
                    name: name,
                    platform: platform,
                    environment: .simulator,
                    osVersion: version,
                    isBooted: (entry["state"] as? String) == Simctl.booted
                ))
            }
        }
        return targets.sorted { ($0.platform.rawValue, $1.osVersion, $0.name) < ($1.platform.rawValue, $0.osVersion, $1.name) }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-27-0` → (.iOS, "27.0")
    static func parseRuntime(_ identifier: String) -> (ApplePlatform, String)? {
        guard identifier.hasPrefix(Simctl.runtimePrefix) else { return nil }
        let parts = identifier.dropFirst(Simctl.runtimePrefix.count).split(separator: "-")
        guard let name = parts.first,
              let platform = ApplePlatform.allCases.first(where: { $0.simulatorRuntimeName == String(name) }) else {
            return nil
        }
        return (platform, parts.dropFirst().joined(separator: "."))
    }

    private static let realityKey = "reality"
    private static let physicalReality = "physical"
    private static let udidKey = "udid"

    /// Physical devices known to CoreDevice (paired, possibly offline).
    public static func devices() async throws -> [RunTarget] {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("swx-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }

        let result = try await ProcessRunner.run([Self.xcrun, "devicectl", "list", "devices", "--json-output", output.path], exitPolicy: .allowFailure)
        guard result.succeeded, let data = FileSystem.readIfPresent(output),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = (json["result"] as? [String: Any])?["devices"] as? [[String: Any]] else {
            return []
        }

        return Self.physicalDevices(in: devices)
    }

    /// `devicectl list devices` entries → physical devices (simulators are listed there too).
    static func physicalDevices(in devices: [[String: Any]]) -> [RunTarget] {
        devices.compactMap { device in
            guard let coreDeviceIdentifier = device["identifier"] as? String,
                  let properties = device["deviceProperties"] as? [String: Any],
                  let hardware = device["hardwareProperties"] as? [String: Any],
                  let platformName = hardware["platform"] as? String,
                  let platform = ApplePlatform(argument: platformName) else {
                return nil
            }

            // devicectl also lists simulators (`reality: simulated`); those come from simctl.
            guard hardware[Self.realityKey] as? String == Self.physicalReality else { return nil }

            // xcodebuild destinations need the hardware UDID; devicectl accepts it too.
            let identifier = hardware[Self.udidKey] as? String ?? coreDeviceIdentifier
            return RunTarget(
                identifier: identifier,
                name: properties["name"] as? String ?? identifier,
                platform: platform,
                environment: .device,
                osVersion: properties["osVersionNumber"] as? String ?? "",
                isBooted: true
            )
        }
    }

    /// The simulator to use: by name/UDID, else a booted one, else the newest runtime's first device.
    public static func pickSimulator(for platform: ApplePlatform, matching query: String?) async throws -> RunTarget {
        let candidates = try await Self.simulators().filter { $0.platform == platform }
        if let query {
            guard let match = candidates.first(where: { $0.identifier == query || $0.name == query }) else {
                throw DeviceError(description: "no available \(platform) simulator named '\(query)'")
            }
            return match
        }
        if let booted = candidates.first(where: \.isBooted) {
            return booted
        }
        guard let newest = candidates.max(by: { Self.compareVersions($0.osVersion, $1.osVersion) }) else {
            throw DeviceError(description: "no \(platform) simulators are installed (Xcode → Settings → Components)")
        }
        return candidates.first { $0.osVersion == newest.osVersion } ?? newest
    }

    public static func pickDevice(for platform: ApplePlatform, matching query: String?) async throws -> RunTarget {
        let candidates = try await Self.devices().filter { $0.platform == platform }
        if let query {
            guard let match = candidates.first(where: { $0.identifier == query || $0.name == query }) else {
                throw DeviceError(description: "no paired \(platform) device named '\(query)'")
            }
            return match
        }
        guard let first = candidates.first else {
            throw DeviceError(description: "no paired \(platform) devices (connect one and trust this Mac)")
        }
        return first
    }

    /// Numeric comparison of dotted versions (`9.0 < 27.0`).
    static func compareVersions(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        return left.lexicographicallyPrecedes(right)
    }

    // MARK: Running

    /// Installs and launches an app, streaming its console until it exits (or Ctrl-C).
    public static func installAndLaunch(app: URL, bundleIdentifier: String, on target: RunTarget, arguments: [String]) async throws -> Never {
        switch target.environment {
        case .simulator:
            try await Self.bootAndInstall(app: app, on: target)
            ProcessRunner.exec([Self.xcrun, "simctl", "launch", "--console-pty", "--terminate-running-process", target.identifier, bundleIdentifier] + arguments)

        case .device:
            try await ProcessRunner.run([Self.xcrun, "devicectl", "device", "install", "app", "--device", target.identifier, app.path])
            ProcessRunner.exec([Self.xcrun, "devicectl", "device", "process", "launch", "--console", "--terminate-existing", "--device", target.identifier, bundleIdentifier] + arguments)
        }
    }

    /// Boots the simulator (booting a booted one is fine) and installs the app on it.
    private static func bootAndInstall(app: URL, on target: RunTarget) async throws {
        let boot = try await ProcessRunner.run([Self.xcrun, "simctl", "boot", target.identifier], exitPolicy: .allowFailure)
        guard boot.succeeded || boot.exitCode == Simctl.alreadyBootedStatus || boot.errorOutput.contains(Simctl.booted) else {
            throw DeviceError(description: "could not boot \(target.name): \(boot.errorOutput)")
        }
        try await ProcessRunner.run([Self.xcrun, "simctl", "install", target.identifier, app.path])
    }

    // MARK: Running alongside swx

    /// simctl hands variables with this prefix to the launched app, without it.
    private static let simulatorEnvironmentPrefix = "SIMCTL_CHILD_"

    /// Installs and launches an app on a simulator, with extra environment variables, as a child
    /// of swx: its console streams here while swx keeps working (hot reload).
    public static func launch(app: URL, bundleIdentifier: String, on target: RunTarget, arguments: [String], environment: [String: String]) async throws -> LaunchedApp {
        guard target.environment == .simulator else {
            throw DeviceError(description: "\(target.name) is a device; this runs on simulators and this Mac")
        }
        try await Self.bootAndInstall(app: app, on: target)

        var variables = ProcessInfo.processInfo.environment
        for (name, value) in environment {
            variables[Self.simulatorEnvironmentPrefix + name] = value
        }
        let identifier = target.identifier
        return try LaunchedApp(
            executable: URL(fileURLWithPath: LaunchedApp.environmentLauncher),
            arguments: [Self.xcrun, "simctl", "launch", "--console-pty", "--terminate-running-process", target.identifier, bundleIdentifier] + arguments,
            environment: variables
        ) { _ in
            _ = try? await ProcessRunner.run([Self.xcrun, "simctl", "terminate", identifier, bundleIdentifier], exitPolicy: .allowFailure)
        }
    }

    /// Runs a Mac app's executable in place, with extra environment variables, as a child of swx.
    public static func launchOnMac(executable: URL, arguments: [String], environment: [String: String]) throws -> LaunchedApp {
        // Started directly: a protected launcher like /usr/bin/env would drop DYLD_* variables.
        try LaunchedApp(executable: executable, arguments: arguments, environment: ProcessInfo.processInfo.environment.merging(environment) { $1 }) { process in
            process.terminate()
        }
    }
}

/// An app swx launched as a child sharing this terminal, and keeps running alongside.
public final class LaunchedApp: @unchecked Sendable {
    static let environmentLauncher = "/usr/bin/env"

    private let process = Process()
    private let stop: @Sendable (Process) async -> Void
    private let exit: AsyncStream<Void>

    init(executable: URL, arguments: [String], environment: [String: String], stop: @escaping @Sendable (Process) async -> Void) throws {
        self.stop = stop
        let (exit, continuation) = AsyncStream<Void>.makeStream()
        self.exit = exit

        self.process.executableURL = executable
        self.process.arguments = arguments
        self.process.environment = environment
        self.process.terminationHandler = { _ in continuation.finish() }
        try self.process.run()
    }

    /// Returns once the app (or its console) has gone.
    public func waitForExit() async {
        for await _ in self.exit {}
    }

    /// Quits the app and waits for its console to close.
    public func terminate() async {
        await self.stop(self.process)
        await self.waitForExit()
    }
}
