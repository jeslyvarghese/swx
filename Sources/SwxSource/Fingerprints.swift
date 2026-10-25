import Foundation
import SwxCore
import SwxSystem

/// What a fingerprint vouches for.
public enum FingerprintContent: Sendable, Hashable {
    case sourceArchive
    /// `Package.swift`, or `Package@swift-<tools version>.swift` when a version is given.
    case manifest(toolsVersion: String?)

    /// SwiftPM's key in the file (`Fingerprint.ContentType.description`).
    var key: String {
        switch self {
        case .sourceArchive:
            return "sourceCode"
        case .manifest(nil):
            return WellKnownFile.manifest
        case .manifest(let toolsVersion?):
            return WellKnownFile.versionSpecificPrefix + toolsVersion + WellKnownFile.swiftExtension
        }
    }
}

/// Trust on first use for registry downloads, in SwiftPM's own store
/// (`<security>/fingerprints/<scope>.<name>.json`, format v2), so both tools agree.
///
/// The first checksum seen for a release is recorded; a later mismatch is an error
/// (SwiftPM's default `strict` mode).
public actor FingerprintStore {
    private enum Key {
        static let version = "version"
        static let versionFingerprints = "versionFingerprints"
        static let kind = "registry"
        static let contentType = "contentType"
        static let fingerprint = "fingerprint"
        static let origin = "origin"
        static let sourceCode = "sourceCode"
        static let manifest = "manifest"
        static let versionSpecificManifest = "versionSpecificManifest"
        static let toolsVersion = "toolsVersion"
        static let toolsVersionValue = "_version"
    }

    private static let formatVersion = 2.0
    private static let directory = "fingerprints"
    private static let fileExtension = "json"

    private let directory: URL

    public init(securityDirectory: URL) {
        self.directory = securityDirectory.appendingPathComponent(Self.directory, isDirectory: true)
    }

    /// The recorded checksum, if any.
    public func recorded(_ identity: PackageIdentity, version: String, content: FingerprintContent) -> String? {
        guard case .object(let entry)? = self.entries(of: identity)[version]?[Key.kind]?[content.key],
              case .string(let fingerprint)? = entry[Key.fingerprint] else {
            return nil
        }
        return fingerprint
    }

    /// Records `checksum` on first use, or fails if a different one was recorded before.
    public func verify(
        _ identity: PackageIdentity,
        version: String,
        content: FingerprintContent,
        checksum: String,
        origin: String
    ) throws {
        if let recorded = self.recorded(identity, version: version, content: content) {
            guard recorded == checksum else {
                throw SourceError(description: "the checksum \(checksum) of \(identity) \(version) \(content.key) does not match the recorded \(recorded)")
            }
            return
        }
        try self.record(identity, version: version, content: content, checksum: checksum, origin: origin)
    }

    // MARK: Storage

    private func file(for identity: PackageIdentity) -> URL {
        self.directory.appendingPathComponent(identity.description).appendingPathExtension(Self.fileExtension)
    }

    private func document(of identity: PackageIdentity) -> [String: JSONValue] {
        guard let data = FileSystem.readIfPresent(self.file(for: identity)),
              case .object(let document)? = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return [:]
        }
        return document
    }

    /// `version → kind → content key → entry`.
    private func entries(of identity: PackageIdentity) -> [String: [String: [String: JSONValue]]] {
        guard case .object(let versions)? = self.document(of: identity)[Key.versionFingerprints] else { return [:] }
        var result: [String: [String: [String: JSONValue]]] = [:]
        for (version, kinds) in versions {
            guard case .object(let kinds) = kinds else { continue }
            for (kind, contents) in kinds {
                guard case .object(let contents) = contents else { continue }
                result[version, default: [:]][kind] = contents
            }
        }
        return result
    }

    /// Adds one entry, keeping everything else in the file (other versions, git fingerprints).
    private func record(_ identity: PackageIdentity, version: String, content: FingerprintContent, checksum: String, origin: String) throws {
        var document = self.document(of: identity)
        var versions: [String: JSONValue] = [:]
        if case .object(let existing)? = document[Key.versionFingerprints] {
            versions = existing
        }
        var kinds: [String: JSONValue] = [:]
        if case .object(let existing)? = versions[version] {
            kinds = existing
        }
        var contents: [String: JSONValue] = [:]
        if case .object(let existing)? = kinds[Key.kind] {
            contents = existing
        }

        contents[content.key] = .object([
            Key.contentType: Self.contentType(content),
            Key.fingerprint: .string(checksum),
            Key.origin: .string(origin),
        ])
        kinds[Key.kind] = .object(contents)
        versions[version] = .object(kinds)
        document[Key.versionFingerprints] = .object(versions)
        document[Key.version] = .number(Self.formatVersion)

        try FileSystem.writeAtomically(try JSONCoding.encoder.encode(JSONValue.object(document)), to: self.file(for: identity))
    }

    /// Swift's synthesized enum coding, as SwiftPM stores it.
    private static func contentType(_ content: FingerprintContent) -> JSONValue {
        switch content {
        case .sourceArchive:
            return .object([Key.sourceCode: .object([:])])
        case .manifest(nil):
            return .object([Key.manifest: .object([:])])
        case .manifest(let toolsVersion?):
            return .object([Key.versionSpecificManifest: .object([
                Key.toolsVersion: .object([Key.toolsVersionValue: .string(toolsVersion)]),
            ])])
        }
    }
}
