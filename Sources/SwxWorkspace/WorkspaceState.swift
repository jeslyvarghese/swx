import Foundation
import SwxCore

/// A dependency SwiftPM considers managed: checked out, or used from a local path.
public struct ManagedDependency: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        case sourceControlCheckout(PinState)
        case fileSystem(path: String)
    }

    public let package: PackageReference
    public let state: State
    /// Directory name under `.build/checkouts`.
    public let subpath: String

    public init(package: PackageReference, state: State, subpath: String) {
        self.package = package
        self.state = state
        self.subpath = subpath
    }
}

/// `.build/workspace-state.json` (format v7), as SwiftPM writes it.
///
/// Artifacts and prebuilts are carried through untouched so `swift build` keeps its own data.
public struct WorkspaceState: Sendable {
    public static let formatVersion = 7

    public var dependencies: [PackageIdentity: ManagedDependency]
    var artifacts: [JSONValue]
    var prebuilts: [JSONValue]

    public init(dependencies: [PackageIdentity: ManagedDependency]) {
        self.dependencies = dependencies
        self.artifacts = []
        self.prebuilts = []
    }

    // MARK: Reading

    /// Returns `nil` for missing files or other format versions (they are simply rewritten).
    public static func decodeIfCompatible(_ data: Data) -> WorkspaceState? {
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.version == Self.formatVersion else {
            return nil
        }
        var dependencies: [PackageIdentity: ManagedDependency] = [:]
        for dependency in stored.object.dependencies {
            guard let managed = dependency.managed else { continue }
            dependencies[managed.package.identity] = managed
        }
        var state = WorkspaceState(dependencies: dependencies)
        state.artifacts = stored.object.artifacts
        state.prebuilts = stored.object.prebuilts
        return state
    }

    // MARK: Writing

    /// Same encoder as SwiftPM; unlike `Package.resolved`, no trailing newline.
    public func encode() throws -> Data {
        let dependencies = self.dependencies.values
            .sorted { $0.package.identity < $1.package.identity }
            .map(StoredDependency.init)
        let stored = Stored(
            object: StoredObject(artifacts: self.artifacts, dependencies: dependencies, prebuilts: self.prebuilts),
            version: Self.formatVersion
        )
        return try JSONCoding.encoder.encode(stored)
    }

    // MARK: Storage format

    private struct Stored: Codable {
        let object: StoredObject
        let version: Int
    }

    private struct StoredObject: Codable {
        let artifacts: [JSONValue]
        let dependencies: [StoredDependency]
        let prebuilts: [JSONValue]

        init(artifacts: [JSONValue], dependencies: [StoredDependency], prebuilts: [JSONValue]) {
            self.artifacts = artifacts
            self.dependencies = dependencies
            self.prebuilts = prebuilts
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.artifacts = try container.decodeIfPresent([JSONValue].self, forKey: .artifacts) ?? []
            self.dependencies = (try? container.decode([StoredDependency].self, forKey: .dependencies)) ?? []
            self.prebuilts = try container.decodeIfPresent([JSONValue].self, forKey: .prebuilts) ?? []
        }
    }

    private struct StoredPackageRef: Codable {
        let identity: String
        let kind: String
        let location: String
        let name: String
    }

    private struct StoredCheckout: Codable {
        let branch: String?
        let revision: String
        let version: String?
    }

    private struct StoredDependencyState: Codable {
        let checkoutState: StoredCheckout?
        let name: String
        let path: String?
    }

    private enum StateName {
        static let sourceControlCheckout = "sourceControlCheckout"
        static let fileSystem = "fileSystem"
    }

    private struct StoredDependency: Codable {
        let packageRef: StoredPackageRef
        let state: StoredDependencyState
        let subpath: String

        private enum CodingKeys: String, CodingKey {
            case basedOn, packageRef, state, subpath
        }

        init(_ dependency: ManagedDependency) {
            self.packageRef = StoredPackageRef(
                identity: dependency.package.identity.description,
                kind: dependency.package.kind.serializedName,
                location: dependency.package.kind.location,
                name: dependency.package.name
            )
            self.subpath = dependency.subpath

            switch dependency.state {
            case .sourceControlCheckout(let pin):
                let checkout: StoredCheckout
                switch pin {
                case .version(let version, let revision):
                    checkout = StoredCheckout(branch: nil, revision: revision, version: version.description)
                case .branch(let branch, let revision):
                    checkout = StoredCheckout(branch: branch, revision: revision, version: nil)
                case .revision(let revision):
                    checkout = StoredCheckout(branch: nil, revision: revision, version: nil)
                }
                self.state = StoredDependencyState(checkoutState: checkout, name: StateName.sourceControlCheckout, path: nil)
            case .fileSystem(let path):
                self.state = StoredDependencyState(checkoutState: nil, name: StateName.fileSystem, path: path)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.packageRef = try container.decode(StoredPackageRef.self, forKey: .packageRef)
            self.state = try container.decode(StoredDependencyState.self, forKey: .state)
            self.subpath = try container.decode(String.self, forKey: .subpath)
        }

        /// SwiftPM always writes `"basedOn" : null` for non-edited dependencies.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeNil(forKey: .basedOn)
            try container.encode(self.packageRef, forKey: .packageRef)
            try container.encode(self.state, forKey: .state)
            try container.encode(self.subpath, forKey: .subpath)
        }

        var managed: ManagedDependency? {
            let kind: PackageKind
            switch self.packageRef.kind {
            case PackageKind.remoteSourceControl(url: "").serializedName:
                kind = .remoteSourceControl(url: self.packageRef.location)
            case PackageKind.fileSystem(path: "").serializedName:
                kind = .fileSystem(path: self.packageRef.location)
            default:
                return nil
            }
            let package = PackageReference(identity: PackageIdentity(plain: self.packageRef.identity), kind: kind)

            switch self.state.name {
            case StateName.sourceControlCheckout:
                guard let checkout = self.state.checkoutState else { return nil }
                let pin: PinState
                if let version = checkout.version.flatMap({ Version($0) }) {
                    pin = .version(version, revision: checkout.revision)
                } else if let branch = checkout.branch {
                    pin = .branch(branch, revision: checkout.revision)
                } else {
                    pin = .revision(checkout.revision)
                }
                return ManagedDependency(package: package, state: .sourceControlCheckout(pin), subpath: self.subpath)
            case StateName.fileSystem:
                return ManagedDependency(package: package, state: .fileSystem(path: self.state.path ?? ""), subpath: self.subpath)
            default:
                return nil
            }
        }
    }
}

/// An opaque JSON value, for round-tripping fields `swx` does not interpret.
enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}
