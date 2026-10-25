import Foundation
import SwxCore
import SwxStore
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

/// Whose fingerprints a file holds; decides the file name and the kind key, as SwiftPM does.
public enum FingerprintSubject: Sendable, Hashable {
    /// `<scope>.<name>.json`, kind `registry`.
    case registry(PackageIdentity)
    /// `<identity>-<8 hex of sha256(canonical location)>.json`, kind `sourceControl`.
    case sourceControl(PackageIdentity, url: String)

    private static let registryKind = "registry"
    private static let sourceControlKind = "sourceControl"
    private static let hashLength = 8
    private static let hashSeparator = "-"
    private static let fileExtension = ".json"

    var kind: String {
        switch self {
        case .registry:
            return Self.registryKind
        case .sourceControl:
            return Self.sourceControlKind
        }
    }

    var fileName: String {
        switch self {
        case .registry(let identity):
            return identity.description + Self.fileExtension
        case .sourceControl(let identity, let url):
            let hash = ContentHash.sha256(CanonicalLocation.compute(url)).prefix(Self.hashLength)
            return identity.description + Self.hashSeparator + hash + Self.fileExtension
        }
    }

    var identity: PackageIdentity {
        switch self {
        case .registry(let identity), .sourceControl(let identity, _):
            return identity
        }
    }
}

/// Trust on first use in SwiftPM's own store (`<security>/fingerprints`, format v2), so both
/// tools agree: registry archive and manifest checksums, and the commit behind each git tag.
///
/// The first value seen for a version is recorded; a later mismatch is an error
/// (SwiftPM's default `strict` mode).
public actor FingerprintStore {
    private enum Key {
        static let version = "version"
        static let versionFingerprints = "versionFingerprints"
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

    private let directory: URL

    public init(securityDirectory: URL) {
        self.directory = securityDirectory.appendingPathComponent(Self.directory, isDirectory: true)
    }

    // MARK: Registry

    /// The recorded registry checksum, if any.
    public func recorded(_ identity: PackageIdentity, version: String, content: FingerprintContent) -> String? {
        self.recorded(.registry(identity), version: version, content: content)
    }

    /// Records a registry checksum on first use, or fails if a different one was recorded before.
    public func verify(
        _ identity: PackageIdentity,
        version: String,
        content: FingerprintContent,
        checksum: String,
        origin: String
    ) throws {
        try self.verify(.registry(identity), version: version, content: content, value: checksum, origin: origin)
    }

    // MARK: Git

    /// SwiftPM's `checkIntegrity`: a tag must keep pointing at the commit first seen for it.
    public func verifyRevision(_ identity: PackageIdentity, url: String, version: String, revision: String) throws {
        let subject = FingerprintSubject.sourceControl(identity, url: url)
        if let recorded = self.recorded(subject, version: version, content: .sourceArchive), recorded != revision {
            throw SourceError(description: "revision \(revision) for \(identity) version \(version) does not match the previously recorded \(recorded) (the tag was moved)")
        }
        try self.verify(subject, version: version, content: .sourceArchive, value: revision, origin: url)
    }

    // MARK: Checking

    private func recorded(_ subject: FingerprintSubject, version: String, content: FingerprintContent) -> String? {
        guard case .object(let entry)? = self.entries(of: subject)[version]?[subject.kind]?[content.key],
              case .string(let fingerprint)? = entry[Key.fingerprint] else {
            return nil
        }
        return fingerprint
    }

    private func verify(_ subject: FingerprintSubject, version: String, content: FingerprintContent, value: String, origin: String) throws {
        if let recorded = self.recorded(subject, version: version, content: content) {
            guard recorded == value else {
                throw SourceError(description: "\(content.key) of \(subject.identity) \(version) is \(value), which does not match the previously recorded \(recorded)")
            }
            return
        }
        try self.record(subject, version: version, content: content, value: value, origin: origin)
    }

    // MARK: Storage

    private func file(for subject: FingerprintSubject) -> URL {
        self.directory.appendingPathComponent(subject.fileName)
    }

    private func document(of subject: FingerprintSubject) -> [String: JSONValue] {
        guard let data = FileSystem.readIfPresent(self.file(for: subject)),
              case .object(let document)? = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return [:]
        }
        return document
    }

    /// `version → kind → content key → entry`.
    private func entries(of subject: FingerprintSubject) -> [String: [String: [String: JSONValue]]] {
        guard case .object(let versions)? = self.document(of: subject)[Key.versionFingerprints] else { return [:] }
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

    /// Adds one entry, keeping everything else in the file.
    private func record(_ subject: FingerprintSubject, version: String, content: FingerprintContent, value: String, origin: String) throws {
        var document = self.document(of: subject)
        var versions: [String: JSONValue] = [:]
        if case .object(let existing)? = document[Key.versionFingerprints] {
            versions = existing
        }
        var kinds: [String: JSONValue] = [:]
        if case .object(let existing)? = versions[version] {
            kinds = existing
        }
        var contents: [String: JSONValue] = [:]
        if case .object(let existing)? = kinds[subject.kind] {
            contents = existing
        }

        contents[content.key] = .object([
            Key.contentType: Self.contentType(content),
            Key.fingerprint: .string(value),
            Key.origin: .string(origin),
        ])
        kinds[subject.kind] = .object(contents)
        versions[version] = .object(kinds)
        document[Key.versionFingerprints] = .object(versions)
        document[Key.version] = .number(Self.formatVersion)

        try FileSystem.writeAtomically(try JSONCoding.encoder.encode(JSONValue.object(document)), to: self.file(for: subject))
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
