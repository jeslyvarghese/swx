import Foundation
import SwxApple
import SwxSystem

/// What to build.
public struct BuildRequest: Sendable {
    public enum Action: String, Sendable {
        case build
        case test
    }

    public let packageDirectory: URL
    public let configuration: String
    public let action: Action
    /// The product (scheme) to build; `nil` builds everything.
    public let product: String?
    public let destination: AppleDestination?
    /// An `.xcodeproj` / `.xcworkspace` to build instead of the package in `packageDirectory`.
    public let container: URL?
    /// Extra arguments forwarded verbatim to the underlying tool.
    public let extraArguments: [String]
    public let codeLoading: CodeLoading

    /// How the built app's code may be replaced while it runs.
    public enum CodeLoading: Sendable {
        case standard
        /// Calls go through rebindable references and every function is exported, so a patch
        /// can replace functions in the running app (`swx run --hot`); the build reports how
        /// it compiled each Swift module.
        case hotReloadable
    }

    public init(
        packageDirectory: URL,
        configuration: String,
        action: Action,
        product: String?,
        destination: AppleDestination?,
        container: URL? = nil,
        extraArguments: [String],
        codeLoading: CodeLoading = .standard
    ) {
        self.packageDirectory = packageDirectory
        self.configuration = configuration
        self.action = action
        self.product = product
        self.destination = destination
        self.container = container
        self.extraArguments = extraArguments
        self.codeLoading = codeLoading
    }
}

/// Where the outputs landed.
public struct BuildResult: Sendable {
    public let productsDirectory: URL
    /// How each Swift module was compiled, for hot-reloadable builds.
    public let swiftModules: [SwiftModuleCommand]

    public init(productsDirectory: URL, swiftModules: [SwiftModuleCommand] = []) {
        self.productsDirectory = productsDirectory
        self.swiftModules = swiftModules
    }
}

public struct BuildError: Error, CustomStringConvertible {
    public let description: String
    /// The build's full log, when it was kept.
    public let log: URL?

    public init(description: String, log: URL? = nil) {
        self.description = description
        self.log = log
    }
}

/// A build backend. Both shipping backends run Apple's open-source swift-build engine:
/// SwiftPM embeds it for host builds, and xcodebuild embeds it for Apple platforms.
public protocol BuildDriver: Sendable {
    func run(_ request: BuildRequest) async throws -> BuildResult
}
