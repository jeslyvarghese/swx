import Foundation
import SwxCore
import SwxSystem

/// A dependency SwiftPM considers managed: checked out, or used from a local path.
public struct ManagedDependency: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        case sourceControlCheckout(PinState)
        case fileSystem(path: String)
        /// Extracted under `.build/registry/downloads/<subpath>`.
        case registryDownload(Version)
    }

    public let package: PackageReference
    public let state: State
    /// Directory name under `.build/checkouts`.
    public let subpath: String
    /// The name SwiftPM records: the manifest's name for path dependencies, else the location's.
    public let name: String

    public init(package: PackageReference, state: State, subpath: String, name: String? = nil) {
        self.package = package
        self.state = state
        self.subpath = subpath
        self.name = name ?? package.name
    }
}

/// A dependency SwiftPM is managing itself (`swift package edit`), which swx must not touch.
public struct EditedDependency: Sendable, Hashable {
    public let subpath: String
    /// The `--path` given to `swift package edit`; `nil` means `Packages/<subpath>`.
    public let path: String?

    public init(subpath: String, path: String?) {
        self.subpath = subpath
        self.path = path
    }
}

/// A binary target's artifact, recorded so SwiftPM sees it as already fetched.
public struct ManagedArtifact: Sendable, Hashable {
    public struct Key: Sendable, Hashable, Comparable {
        public let package: PackageIdentity
        public let targetName: String

        public init(package: PackageIdentity, targetName: String) {
            self.package = package
            self.targetName = targetName
        }

        public static func < (lhs: Key, rhs: Key) -> Bool {
            (lhs.package, lhs.targetName) < (rhs.package, rhs.targetName)
        }
    }

    public enum Source: Sendable, Hashable {
        case remote(url: String, checksum: String)
        case local(checksum: String?)
    }

    public enum Kind: Sendable, Hashable {
        case xcframework
        case artifactsArchive(types: [String])
        case unknown
    }

    public let package: PackageReference
    /// The package's manifest name, as in dependency entries.
    public let packageName: String
    public let targetName: String
    public let source: Source
    public let path: String
    public let kind: Kind

    public init(package: PackageReference, packageName: String, targetName: String, source: Source, path: String, kind: Kind) {
        self.package = package
        self.packageName = packageName
        self.targetName = targetName
        self.source = source
        self.path = path
        self.kind = kind
    }

    public var key: Key {
        Key(package: self.package.identity, targetName: self.targetName)
    }
}

/// What swx needs to know about an artifact entry, whoever wrote it.
public struct RecordedArtifact: Sendable, Hashable {
    public let source: ManagedArtifact.Source?
    public let path: String
}

/// `.build/workspace-state.json` (format v7), as SwiftPM writes it.
///
/// Artifacts, prebuilts and any dependency entry swx doesn't model (edited, custom, …) are
/// carried through untouched, so SwiftPM keeps its own data.
public struct WorkspaceState: Sendable {
    public static let formatVersion = 7

    public var dependencies: [PackageIdentity: ManagedDependency]
    /// Artifact entries as stored; swx rewrites only the ones it manages.
    private var artifacts: [ManagedArtifact.Key: JSONValue] = [:]
    /// Entries without a readable key (kept in place, never touched).
    private var unkeyedArtifacts: [JSONValue] = []
    var prebuilts: [JSONValue]

    /// Raw entries for dependencies swx doesn't manage, keyed by identity.
    private var preserved: [PackageIdentity: JSONValue] = [:]

    public init(dependencies: [PackageIdentity: ManagedDependency]) {
        self.dependencies = dependencies
        self.prebuilts = []
    }

    // MARK: Artifacts

    public var artifactKeys: [ManagedArtifact.Key] {
        self.artifacts.keys.sorted()
    }

    public func artifact(_ key: ManagedArtifact.Key) -> RecordedArtifact? {
        guard case .object(let entry)? = self.artifacts[key], case .string(let path)? = entry[Key.path] else {
            return nil
        }
        return RecordedArtifact(source: Self.artifactSource(entry[Key.source]), path: path)
    }

    public mutating func setArtifact(_ artifact: ManagedArtifact) throws {
        let data = try JSONEncoder().encode(StoredArtifact(artifact))
        self.artifacts[artifact.key] = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public mutating func removeArtifact(_ key: ManagedArtifact.Key) {
        self.artifacts[key] = nil
    }

    private static func artifactSource(_ raw: JSONValue?) -> ManagedArtifact.Source? {
        guard case .object(let source)? = raw, case .string(let type)? = source[Key.type] else { return nil }
        let checksum: String?
        if case .string(let value)? = source[Key.checksum] {
            checksum = value
        } else {
            checksum = nil
        }

        switch type {
        case SourceType.remote:
            guard case .string(let url)? = source[Key.url], let checksum else { return nil }
            return .remote(url: url, checksum: checksum)
        case SourceType.local:
            return .local(checksum: checksum)
        default:
            return nil
        }
    }

    private static func artifactKey(of raw: JSONValue) -> ManagedArtifact.Key? {
        guard case .object(let entry) = raw,
              let identity = Self.identity(of: raw),
              case .string(let targetName)? = entry[Key.targetName] else {
            return nil
        }
        return ManagedArtifact.Key(package: identity, targetName: targetName)
    }

    /// Dependencies under `swift package edit`.
    public var editedDependencies: [PackageIdentity: EditedDependency] {
        var result: [PackageIdentity: EditedDependency] = [:]
        for (identity, raw) in self.preserved {
            guard case .object(let entry) = raw,
                  case .object(let state)? = entry[Key.state],
                  case .string(StateName.edited)? = state[Key.name],
                  case .string(let subpath)? = entry[Key.subpath] else { continue }
            let path: String?
            if case .string(let value)? = state[Key.path] {
                path = value
            } else {
                path = nil
            }
            result[identity] = EditedDependency(subpath: subpath, path: path)
        }
        return result
    }

    /// Identities swx must leave alone (their entries are preserved verbatim).
    public var preservedIdentities: Set<PackageIdentity> {
        Set(self.preserved.keys)
    }

    private enum Key {
        static let state = "state"
        static let name = "name"
        static let path = "path"
        static let subpath = "subpath"
        static let packageRef = "packageRef"
        static let identity = "identity"
        static let targetName = "targetName"
        static let source = "source"
        static let type = "type"
        static let url = "url"
        static let checksum = "checksum"
    }

    private enum SourceType {
        static let remote = "remote"
        static let local = "local"
    }

    // MARK: Reading

    /// Returns `nil` for missing files or other format versions (they are simply rewritten).
    public static func decodeIfCompatible(_ data: Data) -> WorkspaceState? {
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.version == Self.formatVersion else {
            return nil
        }
        // Entries swx understands become models; everything else is kept as-is.
        var dependencies: [PackageIdentity: ManagedDependency] = [:]
        var preserved: [PackageIdentity: JSONValue] = [:]
        for raw in stored.object.dependencies {
            if let managed = Self.model(raw) {
                dependencies[managed.package.identity] = managed
                continue
            }
            guard let identity = Self.identity(of: raw) else { continue }
            preserved[identity] = raw
        }
        var state = WorkspaceState(dependencies: dependencies)
        for raw in stored.object.artifacts {
            guard let key = Self.artifactKey(of: raw) else {
                state.unkeyedArtifacts.append(raw)
                continue
            }
            state.artifacts[key] = raw
        }
        state.prebuilts = stored.object.prebuilts
        state.preserved = preserved
        return state
    }

    private static func model(_ raw: JSONValue) -> ManagedDependency? {
        guard let data = try? JSONEncoder().encode(raw),
              let stored = try? JSONDecoder().decode(StoredDependency.self, from: data) else {
            return nil
        }
        return stored.managed
    }

    private static func identity(of raw: JSONValue) -> PackageIdentity? {
        guard case .object(let entry) = raw,
              case .object(let reference)? = entry[Key.packageRef],
              case .string(let identity)? = reference[Key.identity] else {
            return nil
        }
        return PackageIdentity(plain: identity)
    }

    // MARK: Writing

    /// Same encoder as SwiftPM; unlike `Package.resolved`, no trailing newline.
    public func encode() throws -> Data {
        // Merge managed and preserved entries, sorted by identity like SwiftPM.
        var entries: [(PackageIdentity, JSONValue)] = self.preserved.map { ($0.key, $0.value) }
        for dependency in self.dependencies.values where self.preserved[dependency.package.identity] == nil {
            let data = try JSONEncoder().encode(StoredDependency(dependency))
            entries.append((dependency.package.identity, try JSONDecoder().decode(JSONValue.self, from: data)))
        }
        let dependencies = entries.sorted { $0.0 < $1.0 }.map(\.1)

        // SwiftPM sorts artifacts by identity (its order within a package is arbitrary).
        let artifacts = self.unkeyedArtifacts + self.artifacts.sorted { $0.key < $1.key }.map(\.value)
        let stored = Stored(
            object: StoredObject(artifacts: artifacts, dependencies: dependencies, prebuilts: self.prebuilts),
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
        let dependencies: [JSONValue]
        let prebuilts: [JSONValue]

        init(artifacts: [JSONValue], dependencies: [JSONValue], prebuilts: [JSONValue]) {
            self.artifacts = artifacts
            self.dependencies = dependencies
            self.prebuilts = prebuilts
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.artifacts = try container.decodeIfPresent([JSONValue].self, forKey: .artifacts) ?? []
            self.dependencies = (try? container.decode([JSONValue].self, forKey: .dependencies)) ?? []
            self.prebuilts = try container.decodeIfPresent([JSONValue].self, forKey: .prebuilts) ?? []
        }
    }

    private struct StoredPackageRef: Codable {
        let identity: String
        let kind: String
        let location: String
        let name: String
    }

    /// An artifact entry, field for field as SwiftPM's `Workspace+State` encodes it.
    private struct StoredArtifact: Encodable {
        let kind: ManagedArtifact.Kind
        let packageRef: StoredPackageRef
        let path: String
        let source: ManagedArtifact.Source
        let targetName: String

        init(_ artifact: ManagedArtifact) {
            self.kind = artifact.kind
            self.packageRef = StoredPackageRef(
                identity: artifact.package.identity.description,
                kind: artifact.package.kind.serializedName,
                location: artifact.package.kind.location,
                name: artifact.packageName
            )
            self.path = artifact.path
            self.source = artifact.source
            self.targetName = artifact.targetName
        }
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
        let version: String?

        init(checkoutState: StoredCheckout?, name: String, path: String?, version: String? = nil) {
            self.checkoutState = checkoutState
            self.name = name
            self.path = path
            self.version = version
        }
    }

    private enum StateName {
        static let sourceControlCheckout = "sourceControlCheckout"
        static let fileSystem = "fileSystem"
        static let edited = "edited"
        static let registryDownload = "registryDownload"
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
                name: dependency.name
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
                case .registryVersion(let version):
                    // Not a checkout; registry packages use `.registryDownload`.
                    checkout = StoredCheckout(branch: nil, revision: "", version: version.description)
                }
                self.state = StoredDependencyState(checkoutState: checkout, name: StateName.sourceControlCheckout, path: nil)
            case .fileSystem(let path):
                self.state = StoredDependencyState(checkoutState: nil, name: StateName.fileSystem, path: path)
            case .registryDownload(let version):
                self.state = StoredDependencyState(checkoutState: nil, name: StateName.registryDownload, path: nil, version: version.description)
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
            case PackageKind.localSourceControl(path: "").serializedName:
                kind = .localSourceControl(path: self.packageRef.location)
            case PackageKind.registry(identity: "").serializedName:
                kind = .registry(identity: self.packageRef.identity)
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
                return ManagedDependency(package: package, state: .sourceControlCheckout(pin), subpath: self.subpath, name: self.packageRef.name)
            case StateName.fileSystem:
                return ManagedDependency(package: package, state: .fileSystem(path: self.state.path ?? ""), subpath: self.subpath, name: self.packageRef.name)
            case StateName.registryDownload:
                guard let version = self.state.version.flatMap({ Version($0) }) else { return nil }
                return ManagedDependency(package: package, state: .registryDownload(version), subpath: self.subpath, name: self.packageRef.name)
            default:
                return nil
            }
        }
    }
}

// MARK: Artifact encoding (Swift's synthesized enum coding, as SwiftPM uses it)

extension ManagedArtifact.Kind: Encodable {
    private enum CodingKeys: String, CodingKey {
        case xcframework
        case typedArtifactsArchive
        case unknown
    }

    private enum PayloadKeys: String, CodingKey {
        case types = "_0"
    }

    private struct Empty: Encodable {}

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .xcframework:
            try container.encode(Empty(), forKey: .xcframework)
        case .artifactsArchive(let types):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .typedArtifactsArchive)
            try payload.encode(types, forKey: .types)
        case .unknown:
            try container.encode(Empty(), forKey: .unknown)
        }
    }
}

extension ManagedArtifact.Source: Encodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case url
        case checksum
    }

    private enum SourceType {
        static let remote = "remote"
        static let local = "local"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .remote(let url, let checksum):
            try container.encode(SourceType.remote, forKey: .type)
            try container.encode(url, forKey: .url)
            try container.encode(checksum, forKey: .checksum)
        case .local(let checksum):
            try container.encode(SourceType.local, forKey: .type)
            try container.encodeIfPresent(checksum, forKey: .checksum)
        }
    }
}
