import Foundation
import SwxSystem

/// One configured registry.
public struct Registry: Sendable, Hashable {
    public let url: URL
    /// The registry answers `GET /availability`; SwiftPM checks it before other requests.
    public let supportsAvailability: Bool
}

/// How to authenticate with a registry host (`swift package-registry login`).
public enum RegistryAuthentication: String, Sendable, Hashable, Decodable {
    /// `Authorization: Basic base64(user:password)`.
    case basic
    /// `Authorization: Bearer <password>`.
    case token
}

/// `registries.json` (SwiftPM's format v1): the shared file overlaid by the package's own.
public struct RegistryConfiguration: Sendable {
    private enum Path {
        static let configurationDirectory = ".swiftpm/configuration"
        static let file = "registries.json"
    }

    /// The key SwiftPM uses for the registry that serves every unscoped package.
    private static let defaultScope = "[default]"
    private static let portSeparator = ":"

    public private(set) var defaultRegistry: Registry?
    /// Keyed by lowercased scope (scopes compare case-insensitively).
    private var scopedRegistries: [String: Registry] = [:]
    /// Keyed by `host` or `host:port`.
    private var authentication: [String: RegistryAuthentication] = [:]
    /// `security`: signing settings, by level.
    private var defaultSigning: SigningPolicy.Stored?
    private var registrySigning: [String: SigningPolicy.Stored] = [:]
    private var scopeSigning: [String: SigningPolicy.Stored] = [:]
    private var packageSigning: [String: SigningPolicy.Stored] = [:]

    public static let empty = RegistryConfiguration()

    /// The shared configuration in `configurationDirectory`, overlaid by the package's.
    public static func load(packageDirectory: URL, configurationDirectory: URL) throws -> RegistryConfiguration {
        try Self.load(localDirectory: packageDirectory.appendingPathComponent(Path.configurationDirectory), configurationDirectory: configurationDirectory)
    }

    /// The shared configuration overlaid by the one in `localDirectory` (Xcode keeps it in the
    /// workspace's `xcshareddata/swiftpm/configuration`).
    public static func load(localDirectory: URL, configurationDirectory: URL) throws -> RegistryConfiguration {
        var configuration = RegistryConfiguration()
        configuration.merge(try Self.read(configurationDirectory.appendingPathComponent(Path.file)))
        configuration.merge(try Self.read(localDirectory.appendingPathComponent(Path.file)))
        return configuration
    }

    /// `scope.name` → the registry serving it.
    public func registry(forScope scope: String) -> Registry? {
        self.scopedRegistries[scope.lowercased()] ?? self.defaultRegistry
    }

    public var isConfigured: Bool {
        self.defaultRegistry != nil || !self.scopedRegistries.isEmpty
    }

    /// SwiftPM's storage key: lowercased host, plus the port when the URL has one.
    public func authentication(for url: URL) -> RegistryAuthentication? {
        guard let host = url.host?.lowercased() else { return nil }
        let key = url.port.map { host + Self.portSeparator + String($0) } ?? host
        return self.authentication[key]
    }

    /// SwiftPM's `signing(for:registry:)`: default, then registry host, scope and package overrides.
    public func signingPolicy(scope: String, name: String, registry: Registry) -> SigningPolicy {
        var policy = SigningPolicy.default
        policy.merge(self.defaultSigning)
        if let host = registry.url.host {
            policy.merge(self.registrySigning[host])
        }
        policy.merge(self.scopeSigning[scope.lowercased()])
        policy.merge(self.packageSigning[(scope + "." + name).lowercased()])
        return policy
    }

    // MARK: Reading

    private struct Stored: Decodable {
        struct StoredRegistry: Decodable {
            let url: URL
            let supportsAvailability: Bool?
        }

        struct StoredAuthentication: Decodable {
            let type: RegistryAuthentication
        }

        struct Override: Decodable {
            let signing: SigningPolicy.Stored?
        }

        struct Security: Decodable {
            let `default`: Override?
            let registryOverrides: [String: Override]?
            let scopeOverrides: [String: Override]?
            let packageOverrides: [String: Override]?
        }

        let registries: [String: StoredRegistry]?
        let authentication: [String: StoredAuthentication]?
        let security: Security?
    }

    private static func read(_ url: URL) throws -> RegistryConfiguration? {
        guard let data = FileSystem.readIfPresent(url) else { return nil }
        let stored: Stored
        do {
            stored = try JSONDecoder().decode(Stored.self, from: data)
        } catch {
            throw SourceError(description: "invalid registry configuration at \(url.path): \(error)")
        }

        var configuration = RegistryConfiguration()
        for (scope, entry) in stored.registries ?? [:] {
            let registry = Registry(url: entry.url, supportsAvailability: entry.supportsAvailability ?? false)
            if scope == Self.defaultScope {
                configuration.defaultRegistry = registry
                continue
            }
            configuration.scopedRegistries[scope.lowercased()] = registry
        }
        for (host, entry) in stored.authentication ?? [:] {
            configuration.authentication[host.lowercased()] = entry.type
        }
        configuration.defaultSigning = stored.security?.default?.signing
        configuration.registrySigning = (stored.security?.registryOverrides ?? [:]).compactMapValues(\.signing)
        configuration.scopeSigning = Dictionary((stored.security?.scopeOverrides ?? [:]).compactMapValues(\.signing).map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 })
        configuration.packageSigning = Dictionary((stored.security?.packageOverrides ?? [:]).compactMapValues(\.signing).map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 })
        return configuration
    }

    /// Later files win, entry by entry (SwiftPM's `merge`).
    private mutating func merge(_ other: RegistryConfiguration?) {
        guard let other else { return }
        if let registry = other.defaultRegistry {
            self.defaultRegistry = registry
        }
        self.scopedRegistries.merge(other.scopedRegistries) { $1 }
        self.authentication.merge(other.authentication) { $1 }
        // Security replaces as a whole, as SwiftPM's `merge` does.
        if other.defaultSigning != nil || !other.registrySigning.isEmpty || !other.scopeSigning.isEmpty || !other.packageSigning.isEmpty {
            self.defaultSigning = other.defaultSigning
            self.registrySigning = other.registrySigning
            self.scopeSigning = other.scopeSigning
            self.packageSigning = other.packageSigning
        }
    }
}
