import Foundation
import SwxApple
import SwxBuild
import SwxCore
import SwxDevice
import SwxStore
import SwxSystem

/// Whether to build or run tests.
public enum AppleBuildAction: Sendable {
    case build
    case test

    var request: BuildRequest.Action {
        switch self {
        case .build:
            return .build
        case .test:
            return .test
        }
    }
}

/// What `swx build|run|test --platform …` should target.
public struct AppleTarget: Sendable {
    public let platform: String
    /// `simulator` (default) or `device`.
    public let environment: String
    /// A simulator/device name or identifier.
    public let device: String?
    /// Development team for device signing.
    public let team: String?

    public init(platform: String, environment: String, device: String?, team: String?) {
        self.platform = platform
        self.environment = environment
        self.device = device
        self.team = team
    }
}

/// Builds, runs and tests packages on Apple platforms: swx resolves, xcodebuild builds,
/// simctl/devicectl install and launch.
public struct AppleBuilds: Sendable {
    private enum Layout {
        static let directory = "swx-xcode"
        static let sourcePackages = "SourcePackages"
        static let derivedData = "DerivedData"
        static let appExtension = "app"
        static let infoPlist = "Info.plist"
        static let macOSContents = "Contents"
        static let bundleIdentifierKey = "CFBundleIdentifier"
        static let executableKey = "CFBundleExecutable"
        static let macOSExecutables = "MacOS"
    }

    private let options: WorkspaceOptions
    private let packageDirectory: URL

    public init(options: WorkspaceOptions, packageDirectory: URL) {
        self.options = options
        self.packageDirectory = packageDirectory
    }

    private var stateDirectory: URL {
        self.packageDirectory.appendingPathComponent(WellKnownFile.buildDirectory).appendingPathComponent(Layout.directory)
    }

    // MARK: Commands

    /// Resolves and builds; returns the products directory.
    @discardableResult
    public func build(product: String?, target: AppleTarget, configuration: String, action: AppleBuildAction = .build, extraArguments: [String]) async throws -> URL {
        // Builds don't need a concrete simulator; tests and runs do.
        let destination = try await self.destination(for: target, requirement: action == .build ? .genericAllowed : .concreteRequired)

        // swx checks dependencies out where xcodebuild will look for them. A directory with an
        // Xcode project (and no Package.swift) resolves the project's package references instead.
        let sourcePackages = self.stateDirectory.appendingPathComponent(Layout.sourcePackages)
        let container = self.xcodeContainer()
        let root: WorkspaceRoot = container.map { .xcodeProject($0, sourcePackages: sourcePackages) }
            ?? .packageForXcode(self.packageDirectory, sourcePackages: sourcePackages)
        let workspace = Workspace(options: WorkspaceOptions(
            root: root,
            cacheDirectory: self.options.cacheDirectory,
            maximumConcurrency: self.options.maximumConcurrency,
            verbosity: self.options.verbosity,
            swiftPM: self.options.swiftPM
        ))
        _ = try await workspace.resolve(mode: .respectPins)

        let driver = XcodeBuildDriver(
            sourcePackages: sourcePackages,
            derivedData: self.stateDirectory.appendingPathComponent(Layout.derivedData),
            signing: .automatic(team: target.team),
            // Test runs keep the full log so failures name the failing test.
            output: self.options.verbosity >= .verbose || action == .test ? .full : .quiet
        )
        let request = BuildRequest(
            packageDirectory: self.packageDirectory,
            configuration: configuration,
            action: action.request,
            product: product,
            destination: destination.destination,
            container: container,
            extraArguments: extraArguments
        )
        return try await driver.run(request).productsDirectory
    }

    /// Builds the app product, installs it on the simulator/device and streams its console.
    public func run(product: String, target: AppleTarget, configuration: String, arguments: [String]) async throws -> Never {
        let destination = try await self.destination(for: target, requirement: .concreteRequired)
        let products = try await self.build(product: product, target: target, configuration: configuration, extraArguments: [])

        let app = products.appendingPathComponent(product).appendingPathExtension(Layout.appExtension)
        guard FileSystem.isDirectory(app) else {
            throw WorkspaceError(description: "built \(product) but found no app bundle at \(app.path)")
        }

        // macOS apps simply run in place.
        guard let runTarget = destination.runTarget else {
            let executable = try Self.infoValue(Layout.executableKey, in: app, platform: .macOS)
            ProcessRunner.exec([app.appendingPathComponent(Layout.macOSContents).appendingPathComponent(Layout.macOSExecutables).appendingPathComponent(executable).path] + arguments)
        }
        let bundleIdentifier = try Self.infoValue(Layout.bundleIdentifierKey, in: app, platform: destination.destination.platform)
        try await DeviceRunner.installAndLaunch(app: app, bundleIdentifier: bundleIdentifier, on: runTarget, arguments: arguments)
    }

    /// Simulators and devices, for `swx devices`.
    public static func listTargets() async throws -> [String] {
        let simulators = try await DeviceRunner.simulators()
        let devices = try await DeviceRunner.devices()
        return (devices + simulators).map { target in
            let state = target.environment == .simulator ? (target.isBooted ? " (booted)" : "") : ""
            return "\(target.platform) \(target.osVersion)\t\(target.environment.rawValue)\t\(target.name)\t\(target.identifier)\(state)"
        }
    }

    /// The project or workspace to build when the directory isn't a package.
    private func xcodeContainer() -> URL? {
        guard !FileSystem.exists(self.packageDirectory.appendingPathComponent(WellKnownFile.manifest)) else {
            return nil
        }
        return try? Workspace.locateXcodeProject(in: self.packageDirectory)
    }

    // MARK: Destinations

    private struct ResolvedDestination {
        let destination: AppleDestination
        /// `nil` on macOS (runs in place).
        let runTarget: RunTarget?
    }

    /// Whether a generic destination (no specific simulator/device) is acceptable.
    private enum DestinationRequirement {
        case genericAllowed
        case concreteRequired
    }

    private func destination(for target: AppleTarget, requirement: DestinationRequirement) async throws -> ResolvedDestination {
        guard let platform = ApplePlatform(argument: target.platform) else {
            throw WorkspaceError(description: "unknown platform '\(target.platform)' (use \(ApplePlatform.allCases.map(\.rawValue).joined(separator: ", ")))")
        }
        guard let environment = AppleEnvironment(rawValue: target.environment.lowercased()) else {
            throw WorkspaceError(description: "unknown destination '\(target.environment)' (use simulator or device)")
        }
        if platform == .macOS {
            return ResolvedDestination(destination: AppleDestination(platform: .macOS, environment: .device, deviceIdentifier: nil), runTarget: nil)
        }

        let runTarget: RunTarget
        do {
            switch environment {
            case .simulator:
                runTarget = try await DeviceRunner.pickSimulator(for: platform, matching: target.device)
            case .device:
                runTarget = try await DeviceRunner.pickDevice(for: platform, matching: target.device)
            }
        } catch where requirement == .genericAllowed && target.device == nil {
            // Nothing installed or connected: compile for the generic destination instead.
            return ResolvedDestination(destination: AppleDestination(platform: platform, environment: environment, deviceIdentifier: nil), runTarget: nil)
        }
        return ResolvedDestination(
            destination: AppleDestination(platform: platform, environment: environment, deviceIdentifier: runTarget.identifier),
            runTarget: runTarget
        )
    }

    /// Reads a key from the bundle's Info.plist (macOS bundles keep it under `Contents/`).
    private static func infoValue(_ key: String, in app: URL, platform: ApplePlatform) throws -> String {
        let plist = platform == .macOS
            ? app.appendingPathComponent(Layout.macOSContents).appendingPathComponent(Layout.infoPlist)
            : app.appendingPathComponent(Layout.infoPlist)
        guard let data = FileSystem.readIfPresent(plist),
              let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let value = info[key] as? String else {
            throw WorkspaceError(description: "no \(key) in \(plist.path)")
        }
        return value
    }
}
