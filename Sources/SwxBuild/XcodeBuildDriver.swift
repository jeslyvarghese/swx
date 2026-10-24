import Foundation
import SwxApple
import SwxSystem

/// Builds packages for Apple platforms with xcodebuild, which understands `AppleProductTypes`
/// (app bundles, Info.plist, asset catalogs, signing) natively.
///
/// Dependencies must already be checked out in `sourcePackages` by swx; xcodebuild is told
/// never to resolve on its own.
public struct XcodeBuildDriver: BuildDriver {
    private enum Flag {
        static let clonedSourcePackages = "-clonedSourcePackagesDirPath"
        static let derivedData = "-derivedDataPath"
        static let disableResolution = "-disableAutomaticPackageResolution"
        static let onlyResolvedVersions = "-onlyUsePackageVersionsFromResolvedFile"
        static let skipMacroValidation = "-skipMacroValidation"
        static let allowProvisioningUpdates = "-allowProvisioningUpdates"
        static let quiet = "-quiet"
    }

    private enum Layout {
        static let buildProducts = "Build/Products"
    }

    public let sourcePackages: URL
    public let derivedData: URL
    /// Lets xcodebuild create or download provisioning profiles for device builds.
    public let signing: DeviceSigning

    public enum DeviceSigning: Sendable {
        case automatic(team: String?)
        case manual
    }

    /// How much of xcodebuild's log to show.
    public enum Output: Sendable {
        /// Warnings, errors and test results only (`-quiet`).
        case quiet
        case full
    }

    public let output: Output

    public init(sourcePackages: URL, derivedData: URL, signing: DeviceSigning, output: Output) {
        self.sourcePackages = sourcePackages
        self.derivedData = derivedData
        self.signing = signing
        self.output = output
    }

    public func run(_ request: BuildRequest) async throws -> BuildResult {
        guard let destination = request.destination else {
            throw BuildError(description: "an Apple platform destination is required")
        }
        let scheme = try await self.scheme(for: request)

        var arguments = ["xcodebuild", request.action.rawValue] + Self.containerArguments(request.container) + [
            "-scheme", scheme,
            "-configuration", request.configuration.capitalized,
            "-destination", destination.xcodebuildDestination,
            Flag.derivedData, self.derivedData.path,
            Flag.clonedSourcePackages, self.sourcePackages.path,
            Flag.disableResolution, Flag.onlyResolvedVersions, Flag.skipMacroValidation,
        ]

        // Simulators sign ad hoc by themselves; devices need a team.
        if destination.environment == .device, destination.platform != .macOS, case .automatic(let team) = self.signing {
            arguments.append(Flag.allowProvisioningUpdates)
            if let team {
                arguments.append("DEVELOPMENT_TEAM=\(team)")
            }
        }
        if self.output == .quiet {
            arguments.append(Flag.quiet)
        }
        arguments += request.extraArguments

        // Stream xcodebuild's output live: builds take a while and errors must be visible.
        let status = try await ProcessRunner.runStreaming(arguments, in: request.packageDirectory)
        guard status == 0 else {
            throw BuildError(description: "xcodebuild \(request.action.rawValue) failed (exit \(status))")
        }

        let products = self.derivedData.appendingPathComponent(Layout.buildProducts)
            .appendingPathComponent(destination.productsDirectoryName(configuration: request.configuration.capitalized))
        return BuildResult(productsDirectory: products)
    }

    /// The product's scheme for builds; the package's test scheme for tests.
    private func scheme(for request: BuildRequest) async throws -> String {
        let schemes = try await Self.schemes(in: request.packageDirectory, container: request.container)
        if request.action == .test, let packageScheme = schemes.first(where: { $0.hasSuffix(Self.packageSchemeSuffix) }) {
            return packageScheme
        }
        if let product = request.product {
            guard schemes.contains(product) else {
                throw BuildError(description: "no scheme '\(product)' (available: \(schemes.joined(separator: ", ")))")
            }
            return product
        }
        guard let first = schemes.first else {
            throw BuildError(description: "xcodebuild found no schemes in \(request.packageDirectory.path)")
        }
        return first
    }

    private static let packageSchemeSuffix = "-Package"

    private static let workspaceExtension = "xcworkspace"

    /// `-workspace X` / `-project X`, or nothing for a package directory.
    static func containerArguments(_ container: URL?) -> [String] {
        guard let container else { return [] }
        let flag = container.pathExtension == Self.workspaceExtension ? "-workspace" : "-project"
        return [flag, container.path]
    }

    static func schemes(in directory: URL, container: URL?) async throws -> [String] {
        let result = try await ProcessRunner.run(
            ["xcodebuild", "-list", "-json", Flag.disableResolution] + Self.containerArguments(container),
            in: directory,
            exitPolicy: .allowFailure
        )
        // xcodebuild prints log lines before the JSON object.
        let output = result.output
        guard let start = output.firstIndex(of: "{"),
              let json = try? JSONSerialization.jsonObject(with: Data(output[start...].utf8)) as? [String: Any] else {
            throw BuildError(description: "could not list schemes: \(result.errorOutput.prefix(500))")
        }
        let container = (json["workspace"] ?? json["project"]) as? [String: Any]
        return container?["schemes"] as? [String] ?? []
    }
}
