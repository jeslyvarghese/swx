import Foundation
import SwxCore

/// What a pin records about its package's checkout.
public enum PinState: Sendable, Hashable, CustomStringConvertible {
    case version(Version, revision: String)
    case branch(String, revision: String)
    case revision(String)

    public var revision: String {
        switch self {
        case .version(_, let revision), .branch(_, let revision), .revision(let revision):
            return revision
        }
    }

    public var description: String {
        switch self {
        case .version(let version, _):
            return version.description
        case .branch(let name, _):
            return name
        case .revision(let revision):
            return revision
        }
    }
}

public struct Pin: Sendable, Hashable {
    public let package: PackageReference
    public let state: PinState

    public init(package: PackageReference, state: PinState) {
        self.package = package
        self.state = state
    }
}

/// `Package.resolved`, byte-compatible with SwiftPM (formats v1–v3).
public struct ResolvedFile: Sendable, Hashable {
    public enum FormatVersion: Int, Sendable {
        case v1 = 1
        case v2 = 2
        case v3 = 3

        /// SwiftPM picks the format from the root's minimum tools version.
        public static func forTools(_ toolsVersion: ToolsVersion) -> FormatVersion {
            if toolsVersion > .v5_9 {
                return .v3
            }
            return toolsVersion >= .v5_6 ? .v2 : .v1
        }
    }

    public var pins: [PackageIdentity: Pin]
    public var originHash: String?

    public init(pins: [PackageIdentity: Pin], originHash: String?) {
        self.pins = pins
        self.originHash = originHash
    }

    // MARK: Reading

    public static func decode(_ data: Data) throws -> ResolvedFile {
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: data)

        switch FormatVersion(rawValue: header.version) {
        case .v1:
            let file = try decoder.decode(V1.self, from: data)
            return ResolvedFile(pins: try Self.index(file.object.pins.map { try $0.pin() }), originHash: nil)
        case .v2:
            let file = try decoder.decode(V2.self, from: data)
            return ResolvedFile(pins: try Self.index(file.pins.map { try $0.pin() }), originHash: nil)
        case .v3:
            let file = try decoder.decode(V3.self, from: data)
            return ResolvedFile(pins: try Self.index(file.pins.map { try $0.pin() }), originHash: file.originHash)
        case .none:
            throw WorkspaceError(description: "unknown 'Package.resolved' version '\(header.version)'")
        }
    }

    private static func index(_ pins: [Pin]) throws -> [PackageIdentity: Pin] {
        var result: [PackageIdentity: Pin] = [:]
        for pin in pins {
            guard result[pin.package.identity] == nil else {
                throw WorkspaceError(description: "duplicated entry for package \"\(pin.package.identity)\"")
            }
            result[pin.package.identity] = pin
        }
        return result
    }

    // MARK: Writing

    private static let newline = UInt8(ascii: "\n")

    /// Encodes exactly as SwiftPM: sorted keys, pretty-printed, unescaped slashes, trailing newline.
    public func encode(format: FormatVersion) throws -> Data {
        let sorted = self.pins.values.sorted { $0.package.identity < $1.package.identity }.map(StoredPin.init)

        var data: Data
        switch format {
        case .v3:
            data = try JSONCoding.encoder.encode(V3(originHash: self.originHash, pins: sorted, version: format.rawValue))
        case .v2, .v1:
            // v1 is legacy (tools < 5.6); writing v2 keeps the file readable by every SwiftPM since 5.6.
            data = try JSONCoding.encoder.encode(V2(pins: sorted, version: FormatVersion.v2.rawValue))
        }

        if data.last != Self.newline {
            data.append(Self.newline)
        }
        return data
    }

    // MARK: Storage formats

    private struct Header: Decodable {
        let version: Int
    }

    private struct V3: Codable {
        let originHash: String?
        let pins: [StoredPin]
        let version: Int
    }

    private struct V2: Codable {
        let pins: [StoredPin]
        let version: Int
    }

    private struct StoredPin: Codable {
        let identity: String
        let kind: String
        let location: String
        let state: StoredState

        init(_ pin: Pin) {
            self.identity = pin.package.identity.description
            self.kind = pin.package.kind.serializedName
            self.location = pin.package.kind.location
            self.state = StoredState(pin.state)
        }

        func pin() throws -> Pin {
            let kind: PackageKind
            switch self.kind {
            case PackageKind.remoteSourceControl(url: "").serializedName:
                kind = .remoteSourceControl(url: self.location)
            case PackageKind.localSourceControl(path: "").serializedName:
                kind = .localSourceControl(path: self.location)
            case PackageKind.fileSystem(path: "").serializedName:
                kind = .fileSystem(path: self.location)
            default:
                throw WorkspaceError(description: "unsupported pin kind '\(self.kind)' for \(self.identity)")
            }
            return Pin(package: PackageReference(identity: PackageIdentity(plain: self.identity), kind: kind), state: try self.state.pinState())
        }

    }

    private struct StoredState: Codable {
        let branch: String?
        let revision: String
        let version: String?

        init(_ state: PinState) {
            switch state {
            case .version(let version, let revision):
                self.version = version.description
                self.branch = nil
                self.revision = revision
            case .branch(let branch, let revision):
                self.version = nil
                self.branch = branch
                self.revision = revision
            case .revision(let revision):
                self.version = nil
                self.branch = nil
                self.revision = revision
            }
        }

        func pinState() throws -> PinState {
            if let version {
                guard let parsed = Version(version) else {
                    throw WorkspaceError(description: "invalid version '\(version)' in Package.resolved")
                }
                return .version(parsed, revision: self.revision)
            }
            if let branch {
                return .branch(branch, revision: self.revision)
            }
            return .revision(self.revision)
        }
    }

    private struct V1: Decodable {
        struct Container: Decodable {
            let pins: [LegacyPin]
        }

        struct LegacyPin: Decodable {
            let package: String?
            let repositoryURL: String
            let state: StoredState

            func pin() throws -> Pin {
                Pin(package: .remote(self.repositoryURL), state: try self.state.pinState())
            }
        }

        let object: Container
    }
}

/// SwiftPM's `JSONEncoder.makeWithDefaults()`.
enum JSONCoding {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }
}

public struct WorkspaceError: Error, CustomStringConvertible {
    public let description: String

    public init(description: String) {
        self.description = description
    }
}
