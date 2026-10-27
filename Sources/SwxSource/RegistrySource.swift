import Foundation
import SwxCore
import SwxStore
import SwxSystem

/// Everything resolution and checkout need from Swift package registries (SE-0292).
///
/// Released versions are immutable, so release metadata and manifests are cached in the store
/// and a lockfile restore needs no network beyond the archives themselves.
public actor RegistrySource {
    private let store: Store
    private let configuration: RegistryConfiguration
    private let credentials: RegistryCredentials
    private let fingerprints: FingerprintStore
    private let limiter: ConcurrencyLimiter

    private var releaseTasks: [String: Task<Release, Error>] = [:]
    private var treeTasks: [String: Task<URL, Error>] = [:]
    private var checkedAvailability: Set<URL> = []
    private let signingEntities: SigningEntityStore
    /// Who signed each placed release (`nil`: unsigned or untrusted), for `.registry-metadata`.
    private var signers: [String: SigningEntity] = [:]
    private let warn: @Sendable (String) -> Void
    /// Each warning is reported once, however many manifests and archives repeat it.
    private var reported: Set<String> = []
    private var identityLookups: [String: Task<PackageIdentity?, Error>] = [:]

    private enum MediaType {
        static let json = "json"
        static let swift = "swift"
        static let zip = "zip"
    }

    private enum Header {
        static let accept = "Accept"
        static let authorization = "Authorization"
        static let contentVersion = "Content-Version"
        static let link = "Link"
    }

    private enum Endpoint {
        static let availability = "availability"
        static let zipExtension = ".zip"
        static let swiftVersionQuery = "swift-version"
        static let identifiers = "identifiers"
        static let urlQuery = "url"
    }

    private enum Status {
        static let ok = 200
        static let notFound = 404
    }

    private static let apiVersion = "1"
    private static let sourceArchiveResource = "source-archive"
    private static let archiveDirectory = "extract"
    private static let archiveFileName = "source.zip"
    private static let toolsVersionComment = "// swift-tools-version:"

    public init(
        store: Store,
        configuration: RegistryConfiguration,
        credentials: RegistryCredentials,
        fingerprints: FingerprintStore,
        signingEntities: SigningEntityStore,
        maximumConcurrency: Int,
        warn: @escaping @Sendable (String) -> Void
    ) {
        self.signingEntities = signingEntities
        self.warn = warn
        self.store = store
        self.configuration = configuration
        self.credentials = credentials
        self.fingerprints = fingerprints
        self.limiter = ConcurrencyLimiter(limit: maximumConcurrency)
    }

    // MARK: Versions

    /// Published versions, oldest first, without releases the registry flags with a problem.
    public func versions(of identity: PackageIdentity) async throws -> [Version] {
        let (registry, scope, name) = try self.locate(identity)
        var next: URL? = try Self.url(registry, [scope, name])
        var versions: [Version] = []
        var visited: Set<URL> = []

        // Releases may be paginated (`Link: <…>; rel="next"`); a repeated page ends the walk.
        while let page = next, visited.insert(page).inserted {
            let response = try await self.get(page, accepting: MediaType.json, registry: registry)
            guard response.status != Status.notFound else {
                throw SourceError(description: "\(identity) was not found in the registry at \(registry.url.absoluteString)")
            }
            let releases = try Self.decode(ReleaseList.self, from: response, url: page)
            versions += releases.releases.filter { $0.value.problem == nil }.compactMap { Version($0.key) }
            next = LinkHeader.parse(response.header(Header.link)).first { $0.relation == LinkHeader.next }.flatMap { URL(string: $0.target) }
        }
        return versions.sorted()
    }

    // MARK: Identities

    private struct Identifiers: Decodable {
        let identifiers: [String]
    }

    /// The registry identity of a source-control URL, from the default registry's
    /// `/identifiers` (first in sorted order when several, as SwiftPM picks; `nil` when unmapped).
    public func registryIdentity(forURL url: String) async throws -> PackageIdentity? {
        if let running = self.identityLookups[url] {
            return try await running.value
        }
        let task = Task { try await self.lookUpIdentity(url) }
        self.identityLookups[url] = task
        return try await task.value
    }

    /// The git URL whose lookup produced `identity` (SwiftPM's `identityLookupCache.scmURL(for:)`).
    public func scmURL(forIdentity identity: PackageIdentity) async -> String? {
        for (url, lookup) in self.identityLookups.sorted(by: { $0.key < $1.key }) {
            if (try? await lookup.value) == identity {
                return url
            }
        }
        return nil
    }

    private func lookUpIdentity(_ scmURL: String) async throws -> PackageIdentity? {
        guard let registry = self.configuration.defaultRegistry else { return nil }
        let url = try Self.url(registry, [Endpoint.identifiers], query: [Endpoint.urlQuery: scmURL])
        let response = try await self.get(url, accepting: MediaType.json, registry: registry)
        guard response.status != Status.notFound else { return nil }
        try Self.requireSuccess(response, url: url)
        let identifiers = try Self.decode(Identifiers.self, from: response, url: url).identifiers
        return identifiers.sorted().first.map(PackageIdentity.init(plain:))
    }

    // MARK: Manifests

    /// The manifest SwiftPM would pick for `toolsVersion`, checked against recorded fingerprints.
    public func manifest(of identity: PackageIdentity, version: Version, toolsVersion: ToolsVersion) async throws -> String {
        let release = try await self.release(identity, version)

        // Version-specific manifests are only advertised; like SwiftPM, choose among placeholders
        // declaring their advertised tools version, then fetch the one chosen.
        let fileNames = [WellKnownFile.manifest] + release.alternates.map(\.fileName)
        let chosen = ToolsVersion.selectManifest(fileNames: fileNames, current: toolsVersion) { name in
            if name == WellKnownFile.manifest {
                return release.manifest
            }
            return release.alternates.first { $0.fileName == name }.map { Self.toolsVersionComment + $0.toolsVersion }
        } ?? WellKnownFile.manifest
        guard let alternate = release.alternates.first(where: { $0.fileName == chosen }) else {
            try await self.validateManifestSignature(release.manifest, fileName: WellKnownFile.manifest, identity: identity, version: version, release: release)
            return release.manifest
        }
        let manifest = try await self.alternateManifest(identity, version: version, alternate: alternate, registry: release.registry)
        try await self.validateManifestSignature(manifest, fileName: alternate.fileName, identity: identity, version: version, release: release)
        return manifest
    }

    private func alternateManifest(_ identity: PackageIdentity, version: Version, alternate: Release.Alternate, registry: Registry) async throws -> String {
        let cache = self.store.registryReleasePath(registry: registry.url.absoluteString, identity: identity.description, version: version.description + alternate.fileName)
        let content = FingerprintContent.manifest(toolsVersion: alternate.toolsVersion)
        if let cached = FileSystem.readIfPresent(cache) {
            try await self.fingerprints.verify(identity, version: version.description, content: content, checksum: ContentHash.sha256(cached), origin: registry.url.absoluteString)
            return String(decoding: cached, as: UTF8.self)
        }

        let (_, scope, name) = try self.locate(identity)
        let url = try Self.url(registry, [scope, name, version.description, WellKnownFile.manifest], query: [Endpoint.swiftVersionQuery: alternate.toolsVersion])
        let response = try await self.get(url, accepting: MediaType.swift, registry: registry)
        try Self.requireSuccess(response, url: url)

        try await self.fingerprints.verify(
            identity, version: version.description, content: content,
            checksum: ContentHash.sha256(response.body), origin: registry.url.absoluteString
        )
        try FileSystem.writeAtomically(response.body, to: cache)
        return String(decoding: response.body, as: UTF8.self)
    }

    // MARK: Source archives

    /// The extracted source of a release, downloaded and verified once per checksum.
    public func sourceTree(of identity: PackageIdentity, version: Version) async throws -> URL {
        let release = try await self.release(identity, version)
        let expected = await self.fingerprints.recorded(identity, version: version.description, content: .sourceArchive) ?? release.checksum

        let destination = self.store.registryTreePath(checksum: expected)
        let archive = self.store.registryArchivePath(checksum: expected)
        defer { self.store.markUsed(destination) }
        if !FileSystem.isDirectory(destination) || !FileSystem.exists(archive) {
            if let running = self.treeTasks[expected] {
                _ = try await running.value
            } else {
                let task = Task { try await self.limiter.run { try await self.download(identity, version: version, release: release, expected: expected) } }
                self.treeTasks[expected] = task
                _ = try await task.value
            }
        }

        // The store vouches for the bytes; record them for this security directory, and check the
        // signature under this project's policy every time (it decides `.registry-metadata` too).
        try await self.fingerprints.verify(identity, version: version.description, content: .sourceArchive, checksum: expected, origin: release.registry.url.absoluteString)
        let signer = try await self.validateArchiveSignature(Array(try FileSystem.read(archive)), identity: identity, version: version, release: release)
        self.signers[Self.releaseKey(identity, version)] = signer
        return destination
    }

    private static func releaseKey(_ identity: PackageIdentity, _ version: Version) -> String {
        identity.description.lowercased() + "@" + version.description
    }

    private func download(_ identity: PackageIdentity, version: Version, release: Release, expected: String) async throws -> URL {
        let (registry, scope, name) = try self.locate(identity)
        let url = try Self.url(registry, [scope, name, version.description + Endpoint.zipExtension])
        let response = try await self.get(url, accepting: MediaType.zip, registry: registry)
        try Self.requireSuccess(response, url: url)

        // The archive must match what was recorded (or published) for this release.
        let actual = ContentHash.sha256(response.body)
        guard actual == expected else {
            throw SourceError(description: "the source archive of \(identity) \(version) has checksum \(actual), expected \(expected)")
        }
        try await self.fingerprints.verify(identity, version: version.description, content: .sourceArchive, checksum: actual, origin: registry.url.absoluteString)

        // Extract, drop the single wrapper directory (SwiftPM's `stripFirstLevel`), freeze, publish.
        let staging = try self.store.makeTemporaryDirectory()
        defer { try? FileSystem.removeTree(staging) }
        let archive = staging.appendingPathComponent(Self.archiveFileName)
        try FileSystem.writeAtomically(response.body, to: archive)
        let extracted = staging.appendingPathComponent(Self.archiveDirectory, isDirectory: true)
        try await ArchiveExtraction.unzip(archive, into: extracted)
        let root = try ArchiveExtraction.singleTopLevelDirectory(of: extracted)

        FileSystem.makeReadOnly(root)
        let destination = self.store.registryTreePath(checksum: expected)
        try FileSystem.moveIntoPlace(root, destination)
        try FileSystem.moveIntoPlace(archive, self.store.registryArchivePath(checksum: expected))
        return destination
    }

    /// The `.registry-metadata` file SwiftPM writes next to each download (after `sourceTree`).
    public func releaseMetadataFile(of identity: PackageIdentity, version: Version) async throws -> Data {
        let release = try await self.release(identity, version)
        var file = release.metadataFile
        if let signature = release.signature {
            file.signature = RegistryMetadataFile.Signature(
                signedBy: self.signers[Self.releaseKey(identity, version)].map(RegistryMetadataFile.Signer.init),
                format: signature.format,
                base64: signature.base64
            )
        }
        return try JSONCoding.encoder.encode(file)
    }

    // MARK: Signatures (SwiftPM's SignatureValidation)

    /// Returns the signer of a signed, trusted archive; applies the policy to the rest.
    private func validateArchiveSignature(_ content: [UInt8], identity: PackageIdentity, version: Version, release: Release) async throws -> SigningEntity? {
        let policy = try self.signingPolicy(identity, registry: release.registry)
        let signer: SigningEntity?
        if let signature = release.signature {
            signer = try await self.check(signature: signature.bytes, format: signature.format, content: content, subject: "\(identity) \(version)", identity: identity, policy: policy)
        } else {
            try await self.apply(policy.onUnsigned, message: "\(identity) version \(version) source archive from \(release.registry.url.absoluteString) is not signed")
            signer = nil
        }
        try await self.signingEntities.validate(identity, version: version, signingEntity: signer, registry: release.registry.url.absoluteString)
        return signer
    }

    /// A signed release must have signed manifests too.
    private func validateManifestSignature(_ manifest: String, fileName: String, identity: PackageIdentity, version: Version, release: Release) async throws {
        let policy = try self.signingPolicy(identity, registry: release.registry)
        guard release.signature != nil else {
            // Unsigned releases only prompt here; the archive check already warned.
            if policy.onUnsigned == .prompt {
                try await self.apply(.prompt, message: "\(identity) version \(version) source archive from \(release.registry.url.absoluteString) is not signed")
            }
            return
        }

        let parsed: ManifestSignature?
        do {
            parsed = try ManifestSignature.parse(manifest)
        } catch {
            throw SourceError(description: "\(identity) \(version) \(fileName): manifest signature is malformed")
        }
        guard let parsed else {
            throw SourceError(description: "\(identity) \(version) \(fileName) is not signed, but its source archive is")
        }
        let signer = try await self.check(
            signature: parsed.signature, format: parsed.format, content: parsed.contents,
            subject: "\(identity) \(version) \(fileName)", identity: identity, policy: policy
        )
        try await self.signingEntities.validate(identity, version: version, signingEntity: signer, registry: release.registry.url.absoluteString)
    }

    /// Verifies one signature: invalid ones always fail; untrusted signers follow the policy.
    private func check(signature: [UInt8], format: String, content: [UInt8], subject: String, identity: PackageIdentity, policy: SigningPolicy) async throws -> SigningEntity? {
        guard format == SignatureFormat.cms.rawValue else {
            throw SourceError(description: "\(subject): unknown signature format '\(format)'")
        }
        switch try await SignatureVerifier.status(signature: signature, content: content, policy: policy) {
        case .valid(let signer):
            return signer
        case .invalid(let reason):
            throw SourceError(description: "\(subject): signature is invalid: \(reason)")
        case .certificateInvalid(let reason):
            throw SourceError(description: "\(subject): the signing certificate is invalid: \(reason)")
        case .certificateNotTrusted(let signer):
            try await self.apply(policy.onUntrustedCertificate, message: "the signer \(signer) is not trusted")
            return nil
        }
    }

    private static let prompt = " Continue? (yes/no): "
    private static let yes = ["y", "yes"]

    /// `prompt` asks on a terminal and refuses otherwise; `warn` reports and continues.
    private func apply(_ action: SigningPolicy.Action, message: String) async throws {
        switch action {
        case .silentAllow:
            return
        case .warn:
            if self.reported.insert(message).inserted {
                self.warn(message)
            }
        case .error:
            throw SourceError(description: message)
        case .prompt:
            guard isatty(STDIN_FILENO) != 0 else {
                throw SourceError(description: message + " (refused: no terminal to ask)")
            }
            FileHandle.standardError.write(Data((message + Self.prompt).utf8))
            let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard Self.yes.contains(answer) else { throw SourceError(description: message) }
        }
    }

    private func signingPolicy(_ identity: PackageIdentity, registry: Registry) throws -> SigningPolicy {
        let (_, scope, name) = try self.locate(identity)
        return self.configuration.signingPolicy(scope: scope, name: name, registry: registry)
    }

    // MARK: Releases

    /// Release metadata and the default manifest, from the store or the registry.
    private func release(_ identity: PackageIdentity, _ version: Version) async throws -> Release {
        let (registry, _, _) = try self.locate(identity)
        let key = [registry.url.absoluteString, identity.description.lowercased(), version.description].joined(separator: " ")
        if let running = self.releaseTasks[key] {
            return try await running.value
        }
        let task = Task { try await self.loadRelease(identity, version, registry: registry) }
        self.releaseTasks[key] = task
        return try await task.value
    }

    private func loadRelease(_ identity: PackageIdentity, _ version: Version, registry: Registry) async throws -> Release {
        let cache = self.store.registryReleasePath(registry: registry.url.absoluteString, identity: identity.description, version: version.description)
        if let data = FileSystem.readIfPresent(cache), let cached = try? JSONDecoder().decode(Release.Cached.self, from: data) {
            // Cached bytes still go through trust on first use, for this security directory.
            try await self.fingerprints.verify(
                identity, version: version.description, content: .manifest(toolsVersion: nil),
                checksum: ContentHash.sha256(cached.manifest), origin: registry.url.absoluteString
            )
            return Release(cached: cached, registry: registry)
        }

        // Metadata (with the archive checksum), then the manifest, whose Link header lists alternates.
        let (_, scope, name) = try self.locate(identity)
        let metadataURL = try Self.url(registry, [scope, name, version.description])
        let metadataResponse = try await self.get(metadataURL, accepting: MediaType.json, registry: registry)
        try Self.requireSuccess(metadataResponse, url: metadataURL)
        let metadata = try Self.decode(ReleaseMetadata.self, from: metadataResponse, url: metadataURL)
        guard let checksum = metadata.resources?.first(where: { $0.name == Self.sourceArchiveResource })?.checksum else {
            throw SourceError(description: "\(identity) \(version) has no source archive checksum")
        }

        let manifestURL = try Self.url(registry, [scope, name, version.description, WellKnownFile.manifest])
        let manifestResponse = try await self.get(manifestURL, accepting: MediaType.swift, registry: registry)
        try Self.requireSuccess(manifestResponse, url: manifestURL)
        try await self.fingerprints.verify(
            identity, version: version.description, content: .manifest(toolsVersion: nil),
            checksum: ContentHash.sha256(manifestResponse.body), origin: registry.url.absoluteString
        )
        let alternates = LinkHeader.parse(manifestResponse.header(Header.link)).compactMap(Release.Alternate.init)

        let signing = metadata.resources?.first(where: { $0.name == Self.sourceArchiveResource })?.signing
        let cached = Release.Cached(
            checksum: checksum,
            manifest: String(decoding: manifestResponse.body, as: UTF8.self),
            alternates: alternates,
            metadata: metadata.metadata,
            signature: signing.map { Release.Signature(base64: $0.signatureBase64Encoded, format: $0.signatureFormat) }
        )
        try FileSystem.writeAtomically(try JSONEncoder().encode(cached), to: cache)
        return Release(cached: cached, registry: registry)
    }

    // MARK: HTTP

    private func locate(_ identity: PackageIdentity) throws -> (Registry, scope: String, name: String) {
        guard let (scope, name) = identity.registryComponents else {
            throw SourceError(description: "'\(identity)' is not a registry identity (expected scope.name)")
        }
        guard let registry = self.configuration.registry(forScope: scope) else {
            throw SourceError(description: "no registry is configured for '\(scope)' (swift package-registry set <url>)")
        }
        return (registry, scope, name)
    }

    private func get(_ url: URL, accepting mediaType: String, registry: Registry) async throws -> HTTPResponse {
        try await self.checkAvailability(of: registry)

        var headers = [Header.accept: "application/vnd.swift.registry.v\(Self.apiVersion)+\(mediaType)"]
        if let authorization = await self.authorization(for: registry) {
            headers[Header.authorization] = authorization
        }
        let response = try await HTTP.get(url, headers: headers)

        // A registry that states its API version must speak v1.
        if let version = response.header(Header.contentVersion), version != Self.apiVersion {
            throw SourceError(description: "\(url.absoluteString) speaks registry API version \(version), expected \(Self.apiVersion)")
        }
        return response
    }

    /// Like SwiftPM: any credential found is sent, as the configured type, or by default as basic
    /// auth (bearer when the login is `token`).
    private func authorization(for registry: Registry) async -> String? {
        guard let credential = await self.credentials.credential(for: registry.url) else { return nil }
        let basic = "Basic " + Data("\(credential.login):\(credential.password)".utf8).base64EncodedString()
        let bearer = "Bearer " + credential.password

        switch self.configuration.authentication(for: registry.url) {
        case .basic:
            return basic
        case .token:
            return bearer
        case nil:
            return credential.login == RegistryCredentials.tokenLogin ? bearer : basic
        }
    }

    private func checkAvailability(of registry: Registry) async throws {
        guard registry.supportsAvailability, !self.checkedAvailability.contains(registry.url) else { return }
        let url = try Self.url(registry, [Endpoint.availability])
        let response = try await HTTP.get(url, headers: [:])
        guard response.status == Status.ok else {
            throw SourceError(description: "the registry at \(registry.url.absoluteString) is not available (HTTP \(response.status))")
        }
        self.checkedAvailability.insert(registry.url)
    }

    private static func url(_ registry: Registry, _ components: [String], query: [String: String] = [:]) throws -> URL {
        var url = registry.url
        for component in components {
            url.appendPathComponent(component)
        }
        guard !query.isEmpty else { return url }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw SourceError(description: "invalid registry URL \(url.absoluteString)")
        }
        parts.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let withQuery = parts.url else {
            throw SourceError(description: "invalid registry URL \(url.absoluteString)")
        }
        return withQuery
    }

    private static func requireSuccess(_ response: HTTPResponse, url: URL) throws {
        guard response.status == Status.ok else {
            throw SourceError(description: "\(url.absoluteString): HTTP \(response.status)")
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from response: HTTPResponse, url: URL) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: response.body)
        } catch {
            throw SourceError(description: "\(url.absoluteString): unexpected response: \(error)")
        }
    }
}

// MARK: - Wire formats

/// `GET /{scope}/{name}`.
private struct ReleaseList: Decodable {
    struct Entry: Decodable {
        let problem: JSONValue?
    }

    let releases: [String: Entry]
}

/// `GET /{scope}/{name}/{version}`.
private struct ReleaseMetadata: Decodable {
    struct Resource: Decodable {
        struct Signing: Decodable {
            let signatureBase64Encoded: String
            let signatureFormat: String
        }

        let name: String
        let checksum: String?
        let signing: Signing?
    }

    let resources: [Resource]?
    let metadata: PackageMetadata?
}

/// The descriptive part of release metadata, which SwiftPM copies into `.registry-metadata`.
struct PackageMetadata: Codable, Sendable {
    struct Organization: Codable, Sendable {
        let name: String
        let email: String?
        let description: String?
        let url: String?
    }

    struct Author: Codable, Sendable {
        let name: String
        let email: String?
        let description: String?
        let organization: Organization?
        let url: String?
    }

    let author: Author?
    let description: String?
    let licenseURL: String?
    let readmeURL: String?
    let repositoryURLs: [String]?
}

/// `.registry-metadata`, field for field as SwiftPM's `CodableRegistryReleaseMetadata`.
private struct RegistryMetadataFile: Encodable, Sendable {
    struct Organization: Encodable, Sendable {
        let name: String
        let emailAddress: String?
        let description: String?
        let url: String?
    }

    struct Author: Encodable, Sendable {
        let name: String
        let emailAddress: String?
        let description: String?
        let url: String?
        let organization: Organization?
    }

    /// SwiftPM's `SourceControlURL` encodes as an object.
    struct SourceControlURL: Encodable, Sendable {
        let urlString: String
    }

    /// SwiftPM's `CodableRegistryReleaseMetadata.SigningEntity` (synthesized enum coding).
    enum Signer: Encodable, Sendable {
        case recognized(type: String, commonName: String?, organization: String?, identity: String?)
        case unrecognized(commonName: String?, organization: String?)

        init(_ entity: SigningEntity) {
            switch entity {
            case .recognized(let type, let name, let unit, let organization):
                self = .recognized(type: type, commonName: name, organization: organization, identity: unit)
            case .unrecognized(let name, _, let organization):
                self = .unrecognized(commonName: name, organization: organization)
            }
        }
    }

    struct Signature: Encodable, Sendable {
        let signedBy: Signer?
        let format: String
        let base64: String
    }

    let registry: String
    var signature: Signature?
    let author: Author?
    let description: String?
    let licenseURL: String?
    let readmeURL: String?
    let scmRepositoryURLs: [SourceControlURL]?
}

/// One release as resolution and checkout use it.
private struct Release: Sendable {
    /// A version-specific manifest advertised in the manifest's `Link` header.
    struct Alternate: Codable, Sendable {
        let fileName: String
        let toolsVersion: String

        private static let alternateRelation = "alternate"
        private static let fileNameField = "filename"
        private static let toolsVersionField = "swift-tools-version"

        init?(_ link: LinkHeader.Entry) {
            guard link.relation == Self.alternateRelation,
                  let fileName = link.fields[Self.fileNameField],
                  let declared = link.fields[Self.toolsVersionField],
                  let toolsVersion = ToolsVersion.parse(versionText: declared) else {
                return nil
            }
            self.fileName = fileName
            self.toolsVersion = toolsVersion.description
        }
    }

    /// The source archive's signature, as published.
    struct Signature: Codable, Sendable {
        let base64: String
        let format: String

        var bytes: [UInt8] {
            Array(Data(base64Encoded: self.base64) ?? Data())
        }
    }

    /// What the store keeps per release.
    struct Cached: Codable, Sendable {
        let checksum: String
        let manifest: String
        let alternates: [Alternate]
        let metadata: PackageMetadata?
        let signature: Signature?
    }

    let registry: Registry
    let checksum: String
    let manifest: String
    let alternates: [Alternate]
    let signature: Signature?
    let metadataFile: RegistryMetadataFile

    init(cached: Cached, registry: Registry) {
        self.registry = registry
        self.checksum = cached.checksum
        self.manifest = cached.manifest
        self.alternates = cached.alternates
        self.signature = cached.signature

        let metadata = cached.metadata
        self.metadataFile = RegistryMetadataFile(
            registry: registry.url.absoluteString,
            signature: nil,
            author: metadata?.author.map { author in
                RegistryMetadataFile.Author(
                    name: author.name,
                    emailAddress: author.email,
                    description: author.description,
                    url: author.url,
                    organization: author.organization.map {
                        RegistryMetadataFile.Organization(name: $0.name, emailAddress: $0.email, description: $0.description, url: $0.url)
                    }
                )
            },
            description: metadata?.description,
            licenseURL: metadata?.licenseURL,
            readmeURL: metadata?.readmeURL,
            scmRepositoryURLs: metadata?.repositoryURLs?.map(RegistryMetadataFile.SourceControlURL.init)
        )
    }
}

/// RFC 8288 `Link` headers: `<url>; rel="next", <url>; rel="alternate"; filename="…"`.
enum LinkHeader {
    struct Entry: Sendable, Hashable {
        let target: String
        let relation: String?
        let fields: [String: String]
    }

    static let next = "next"
    private static let relationField = "rel"

    static func parse(_ header: String?) -> [Entry] {
        guard let header else { return [] }
        return Self.splitEntries(header).compactMap { entry in
            let parts = entry.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = parts.first, first.hasPrefix("<"), first.hasSuffix(">") else { return nil }

            var fields: [String: String] = [:]
            for part in parts.dropFirst() {
                guard let equals = part.firstIndex(of: "=") else { continue }
                let key = part[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                let value = part[part.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                fields[key] = value
            }
            return Entry(target: String(first.dropFirst().dropLast()), relation: fields[Self.relationField], fields: fields)
        }
    }

    /// Splits on commas outside `<…>` and quotes (URLs and parameters may contain commas).
    private static func splitEntries(_ header: String) -> [String] {
        var entries: [String] = []
        var current = ""
        var inTarget = false
        var inQuotes = false
        for character in header {
            switch character {
            case "<" where !inQuotes:
                inTarget = true
            case ">" where !inQuotes:
                inTarget = false
            case "\"" where !inTarget:
                inQuotes.toggle()
            case "," where !inTarget && !inQuotes:
                entries.append(current)
                current = ""
                continue
            default:
                break
            }
            current.append(character)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            entries.append(current)
        }
        return entries
    }
}
