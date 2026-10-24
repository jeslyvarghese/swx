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

    public init(
        packageDirectory: URL,
        configuration: String,
        action: Action,
        product: String?,
        destination: AppleDestination?,
        container: URL? = nil,
        extraArguments: [String]
    ) {
        self.packageDirectory = packageDirectory
        self.configuration = configuration
        self.action = action
        self.product = product
        self.destination = destination
        self.container = container
        self.extraArguments = extraArguments
    }
}

/// Where the outputs landed.
public struct BuildResult: Sendable {
    public let productsDirectory: URL
}

public struct BuildError: Error, CustomStringConvertible {
    public let description: String
}

/// A build backend. Both shipping backends run Apple's open-source swift-build engine:
/// SwiftPM embeds it for host builds, and xcodebuild embeds it for Apple platforms.
public protocol BuildDriver: Sendable {
    func run(_ request: BuildRequest) async throws -> BuildResult
}
