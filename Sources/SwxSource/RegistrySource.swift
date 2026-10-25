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
        maximumConcurrency: Int
    ) {
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
            return release.manifest
        }
        return try await self.alternateManifest(identity, version: version, alternate: alternate, registry: release.registry)
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
        if FileSystem.isDirectory(destination) {
            // The store already holds these bytes; still record them for this security directory.
            try await self.fingerprints.verify(identity, version: version.description, content: .sourceArchive, checksum: expected, origin: release.registry.url.absoluteString)
            return destination
        }
        if let running = self.treeTasks[expected] {
            return try await running.value
        }
        let task = Task { try await self.limiter.run { try await self.download(identity, version: version, release: release, expected: expected) } }
        self.treeTasks[expected] = task
        return try await task.value
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
        return destination
    }

    /// The `.registry-metadata` file SwiftPM writes next to each download.
    public func releaseMetadataFile(of identity: PackageIdentity, version: Version) async throws -> Data {
        let release = try await self.release(identity, version)
        return try JSONCoding.encoder.encode(release.metadataFile)
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

        let cached = Release.Cached(
            checksum: checksum,
            manifest: String(decoding: manifestResponse.body, as: UTF8.self),
            alternates: alternates,
            metadata: metadata.metadata
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
        let name: String
        let checksum: String?
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

    let registry: String
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

    /// What the store keeps per release.
    struct Cached: Codable, Sendable {
        let checksum: String
        let manifest: String
        let alternates: [Alternate]
        let metadata: PackageMetadata?
    }

    let registry: Registry
    let checksum: String
    let manifest: String
    let alternates: [Alternate]
    let metadataFile: RegistryMetadataFile

    init(cached: Cached, registry: Registry) {
        self.registry = registry
        self.checksum = cached.checksum
        self.manifest = cached.manifest
        self.alternates = cached.alternates

        let metadata = cached.metadata
        self.metadataFile = RegistryMetadataFile(
            registry: registry.url.absoluteString,
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
