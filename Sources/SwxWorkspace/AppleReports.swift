import Foundation
import SwxApple
import SwxBuild
import SwxDevice
import SwxSystem

/// `--format json` for Apple platforms: builds and tests report diagnostics and test results,
/// and runs launch the app without holding on to its console.
extension AppleBuilds {
    private enum ReportLayout {
        static let logs = "logs"
        static let logExtension = "log"
        static let resultBundle = "test.xcresult"
        static let appLog = "app.log"
    }

    private var logsDirectory: URL {
        self.stateDirectory.appendingPathComponent(ReportLayout.logs)
    }

    /// Builds or tests with xcodebuild's output in a log, and reports it.
    public func report(product: String?, target: AppleTarget, configuration: String, action: AppleBuildAction, extraArguments: [String]) async throws -> CommandReport {
        let command: ReportedCommand = action == .test ? .test : .build
        let log = self.logsDirectory.appendingPathComponent(command.rawValue).appendingPathExtension(ReportLayout.logExtension)
        let resultBundle = self.logsDirectory.appendingPathComponent(ReportLayout.resultBundle)
        let start = ContinuousClock.now

        // A failing build is a report; anything else (no simulator, bad platform) is an error.
        var products: URL?
        var exitCode: Int32 = 0
        do {
            products = try await self.build(
                product: product, target: target, configuration: configuration, action: action, extraArguments: extraArguments,
                codeLoading: .standard, output: .captured(log: log, resultBundle: resultBundle)
            ).productsDirectory
        } catch let error as BuildError where error.log != nil {
            exitCode = 1
        }

        let text = String(decoding: FileSystem.readIfPresent(log) ?? Data(), as: UTF8.self)
        let tests = action == .test ? await Self.testResults(in: resultBundle) : nil
        return CommandReport(command: command, exitCode: exitCode, seconds: CommandReport.seconds(since: start), log: log, logText: text, tests: tests, products: products?.path)
    }

    /// The result bundle's tests, through xcresulttool.
    private static func testResults(in bundle: URL) async -> TestReport? {
        guard FileSystem.exists(bundle) else { return nil }
        let result = try? await ProcessRunner.run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", bundle.path], exitPolicy: .allowFailure)
        guard let result, result.succeeded else { return nil }
        return XCResultTests.report(from: result.standardOutput)
    }

    /// Builds the app and launches it in the background (a simulator, or this Mac with its
    /// output in a log); the report names the app.
    public func runReporting(product: String, target: AppleTarget, configuration: String, arguments: [String]) async throws -> CommandReport {
        let destination = try await self.destination(for: target, requirement: .concreteRequired)
        let build = try await self.report(product: product, target: target, configuration: configuration, action: .build, extraArguments: [])
        guard build.status == .succeeded, let products = build.products else { return build }

        let app = URL(fileURLWithPath: products).appendingPathComponent(product).appendingPathExtension(Self.appExtension)
        guard FileSystem.isDirectory(app) else {
            throw WorkspaceError(description: "built \(product) but found no app bundle at \(app.path)", code: .noAppBundle, fix: "pass an app product (an .iOSApplication or an app target) to run")
        }

        // Launch, then report the build with what was launched.
        var output: String?
        if let runTarget = destination.runTarget {
            let bundleIdentifier = try Self.infoValue(Self.bundleIdentifierKey, in: app, platform: destination.destination.platform)
            try await DeviceRunner.launchInBackground(app: app, bundleIdentifier: bundleIdentifier, on: runTarget, arguments: arguments)
            output = "launched \(bundleIdentifier) on \(runTarget.name) (\(runTarget.identifier))"
        } else {
            let executable = try Self.infoValue(Self.executableKey, in: app, platform: .macOS)
            let path = app.appendingPathComponent(Self.macOSContents).appendingPathComponent(Self.macOSExecutables).appendingPathComponent(executable)
            let appLog = self.logsDirectory.appendingPathComponent(ReportLayout.appLog)
            let pid = try ProcessControl.spawnDetached([path.path] + arguments, environment: ProcessInfo.processInfo.environment, output: appLog)
            output = "launched \(product) (pid \(pid)); its output goes to \(appLog.path)"
        }
        let logText = String(decoding: FileSystem.readIfPresent(URL(fileURLWithPath: build.log)) ?? Data(), as: UTF8.self)
        return CommandReport(command: .run, exitCode: 0, seconds: build.seconds, log: URL(fileURLWithPath: build.log), logText: logText, products: app.path, output: output)
    }

    // MARK: Devices

    /// A simulator or device, for `swx devices --format json`.
    public struct DeviceSummary: Sendable, Encodable {
        public let platform: String
        public let osVersion: String
        public let kind: String
        public let name: String
        public let identifier: String
        public let booted: Bool
    }

    public static func deviceSummaries() async throws -> [DeviceSummary] {
        let targets = try await DeviceRunner.devices() + DeviceRunner.simulators()
        return targets.map {
            DeviceSummary(platform: $0.platform.rawValue, osVersion: $0.osVersion, kind: $0.environment.rawValue, name: $0.name, identifier: $0.identifier, booted: $0.isBooted)
        }
    }
}
