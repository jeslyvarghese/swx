/// Apple platforms swx can build and run apps for.
public enum ApplePlatform: String, Sendable, CaseIterable, CustomStringConvertible {
    case iOS = "ios"
    case watchOS = "watchos"
    case tvOS = "tvos"
    case visionOS = "visionos"
    case macOS = "macos"

    /// Accepts `ios`, `iOS`, `watchOS`, `xros`, … as typed on the command line.
    public init?(argument: String) {
        let lowered = argument.lowercased()
        if lowered == Self.visionOSAlias {
            self = .visionOS
            return
        }
        self.init(rawValue: lowered)
    }

    private static let visionOSAlias = "xros"

    public var description: String {
        switch self {
        case .iOS:
            return "iOS"
        case .watchOS:
            return "watchOS"
        case .tvOS:
            return "tvOS"
        case .visionOS:
            return "visionOS"
        case .macOS:
            return "macOS"
        }
    }

    /// The prefix of simulator runtime identifiers (`com.apple.CoreSimulator.SimRuntime.iOS-27-0`).
    public var simulatorRuntimeName: String? {
        switch self {
        case .iOS:
            return "iOS"
        case .watchOS:
            return "watchOS"
        case .tvOS:
            return "tvOS"
        case .visionOS:
            return "xrOS"
        case .macOS:
            return nil
        }
    }

    /// The SDK directory suffix used in build product folders (`Debug-iphonesimulator`).
    func sdkName(for environment: AppleEnvironment) -> String {
        switch (self, environment) {
        case (.iOS, .simulator):
            return "iphonesimulator"
        case (.iOS, .device):
            return "iphoneos"
        case (.watchOS, .simulator):
            return "watchsimulator"
        case (.watchOS, .device):
            return "watchos"
        case (.tvOS, .simulator):
            return "appletvsimulator"
        case (.tvOS, .device):
            return "appletvos"
        case (.visionOS, .simulator):
            return "xrsimulator"
        case (.visionOS, .device):
            return "xros"
        case (.macOS, _):
            return "macosx"
        }
    }

    /// xcodebuild's `platform=` value.
    func destinationPlatform(for environment: AppleEnvironment) -> String {
        switch (self, environment) {
        case (.macOS, _):
            return "macOS"
        case (_, .simulator):
            return "\(self) Simulator"
        case (_, .device):
            return self.description
        }
    }
}

/// Where an app runs.
public enum AppleEnvironment: String, Sendable, CaseIterable {
    case simulator
    case device
}

/// A concrete or generic build/run destination.
public struct AppleDestination: Sendable, Hashable, CustomStringConvertible {
    public let platform: ApplePlatform
    public let environment: AppleEnvironment
    /// A simulator UDID or device identifier; `nil` builds for the generic destination.
    public let deviceIdentifier: String?

    public init(platform: ApplePlatform, environment: AppleEnvironment, deviceIdentifier: String?) {
        self.platform = platform
        // macOS has no simulator: everything runs on this Mac.
        self.environment = platform == .macOS ? .device : environment
        self.deviceIdentifier = deviceIdentifier
    }

    /// The `-destination` argument for xcodebuild.
    public var xcodebuildDestination: String {
        let platform = self.platform.destinationPlatform(for: self.environment)
        guard let deviceIdentifier else {
            return "generic/platform=\(platform)"
        }
        return "platform=\(platform),id=\(deviceIdentifier)"
    }

    /// `Debug-iphonesimulator`, `Release-iphoneos`, `Debug` (macOS).
    public func productsDirectoryName(configuration: String) -> String {
        guard self.platform != .macOS else {
            return configuration
        }
        return "\(configuration)-\(self.platform.sdkName(for: self.environment))"
    }

    public var description: String {
        "\(self.platform) \(self.environment.rawValue)\(self.deviceIdentifier.map { " \($0)" } ?? "")"
    }
}
