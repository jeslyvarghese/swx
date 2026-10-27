import Crypto
import Foundation
import SwxSystem

/// Where a remote cache keeps its files: a key → bytes store.
public protocol RemoteStorage: Sendable {
    func contains(_ key: String) async throws -> Bool
    /// Downloads `key` to `file`; `false` when the remote doesn't have it.
    func download(_ key: String, to file: URL) async throws -> Bool
    func upload(_ file: URL, as key: String) async throws
    /// Every object whose key starts with `prefix`, for `swx cache size` and `prune`.
    func list(prefix: String) async throws -> [RemoteObject]
    func delete(_ key: String) async throws
}

/// One object in a remote cache.
public struct RemoteObject: Sendable, Equatable {
    public let key: String
    public let bytes: Int64
    /// When it was last written; a directory remote also counts downloads.
    public let modified: Date

    public init(key: String, bytes: Int64, modified: Date) {
        self.key = key
        self.bytes = bytes
        self.modified = modified
    }
}

public struct RemoteStorageError: Error, CustomStringConvertible, Sendable {
    public let description: String
}

/// Builds the storage a remote cache location names.
public enum RemoteStorages {
    private enum Scheme {
        static let file = "file"
        static let http = "http"
        static let https = "https"
        static let s3 = "s3"
    }

    /// Environment the backends read their credentials and endpoints from.
    public enum Variable {
        public static let token = "SWX_REMOTE_CACHE_TOKEN"
        static let s3Endpoint = "SWX_S3_ENDPOINT"
        static let accessKey = "AWS_ACCESS_KEY_ID"
        static let secretKey = "AWS_SECRET_ACCESS_KEY"
        static let sessionToken = "AWS_SESSION_TOKEN"
        static let region = "AWS_REGION"
        static let defaultRegion = "AWS_DEFAULT_REGION"
    }

    private static let fallbackRegion = "us-east-1"

    /// `file:///path` or a plain path, `http(s)://host/prefix`, or `s3://bucket/prefix`.
    public static func make(_ location: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> RemoteStorage {
        guard let url = URL(string: location), let scheme = url.scheme?.lowercased() else {
            return DirectoryStorage(root: URL(fileURLWithPath: location, isDirectory: true))
        }
        switch scheme {
        case Scheme.file:
            return DirectoryStorage(root: URL(fileURLWithPath: url.path, isDirectory: true))
        case Scheme.http, Scheme.https:
            return HTTPStorage(base: url, token: environment[Variable.token])
        case Scheme.s3:
            guard let bucket = url.host, !bucket.isEmpty else {
                throw RemoteStorageError(description: "\(location): an S3 location is s3://bucket/prefix")
            }
            guard let accessKey = environment[Variable.accessKey], let secretKey = environment[Variable.secretKey] else {
                throw RemoteStorageError(description: "\(location): set \(Variable.accessKey) and \(Variable.secretKey)")
            }
            let endpoint = try environment[Variable.s3Endpoint].map { text -> URL in
                guard let endpoint = URL(string: text) else {
                    throw RemoteStorageError(description: "\(Variable.s3Endpoint) is not a URL: \(text)")
                }
                return endpoint
            }
            return S3Storage(
                bucket: bucket,
                prefix: url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                region: environment[Variable.region] ?? environment[Variable.defaultRegion] ?? Self.fallbackRegion,
                endpoint: endpoint,
                credentials: S3Storage.Credentials(accessKey: accessKey, secretKey: secretKey, sessionToken: environment[Variable.sessionToken])
            )
        default:
            throw RemoteStorageError(description: "\(location): use a path, file://, http(s):// or s3:// location")
        }
    }
}

// MARK: - Directory

/// A directory: a mounted network drive, or a folder CI caches between runs.
struct DirectoryStorage: RemoteStorage {
    let root: URL

    func contains(_ key: String) async throws -> Bool {
        FileSystem.exists(self.root.appendingPathComponent(key))
    }

    func download(_ key: String, to file: URL) async throws -> Bool {
        let source = self.root.appendingPathComponent(key)
        guard FileSystem.exists(source) else { return false }
        try FileSystem.createDirectory(file.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.copyItem(at: source, to: file)

        // Age counts from the last use, so `swx cache prune --remote` keeps what CI still pulls.
        try? FileSystem.touch(source)
        return true
    }

    func list(prefix: String) async throws -> [RemoteObject] {
        Self.files(under: self.root.standardizedFileURL, prefix: prefix)
    }

    private static func files(under base: URL, prefix: String) -> [RemoteObject] {
        let start = base.appendingPathComponent(prefix)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: start, includingPropertiesForKeys: Array(keys)) else {
            return []
        }

        var objects: [RemoteObject] = []
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            // Uploads stage under a dot-name before they are renamed into place.
            guard !file.lastPathComponent.hasPrefix(Self.stagingPrefix) else { continue }
            let key = String(file.standardizedFileURL.path.dropFirst(base.path.count + 1))
            objects.append(RemoteObject(key: key, bytes: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast))
        }
        return objects.sorted { $0.key < $1.key }
    }

    func delete(_ key: String) async throws {
        try FileSystem.removeTree(self.root.appendingPathComponent(key))
    }

    private static let stagingPrefix = "."

    /// Copied beside the destination, then renamed, so readers never see half a file.
    func upload(_ file: URL, as key: String) async throws {
        let destination = self.root.appendingPathComponent(key)
        try FileSystem.createDirectory(destination.deletingLastPathComponent())
        let staging = destination.deletingLastPathComponent().appendingPathComponent(Self.stagingPrefix + UUID().uuidString)
        try FileManager.default.copyItem(at: file, to: staging)
        try FileSystem.replace(destination, with: staging)
    }
}

// MARK: - HTTP

/// Any server that answers GET, HEAD and PUT under a base URL (nginx WebDAV, a CDN bucket, …).
struct HTTPStorage: RemoteStorage {
    let base: URL
    let token: String?

    private static let notFound = 404
    private static let successCodes = 200..<300

    private var headers: [String: String] {
        self.token.map { ["Authorization": "Bearer \($0)"] } ?? [:]
    }

    private func url(_ key: String) -> URL {
        self.base.appendingPathComponent(key)
    }

    func contains(_ key: String) async throws -> Bool {
        let status = try await HTTP.head(self.url(key), headers: self.headers)
        return try Self.found(status, key: key)
    }

    func download(_ key: String, to file: URL) async throws -> Bool {
        let status = try await HTTP.download(self.url(key), headers: self.headers, to: file)
        return try Self.found(status, key: key)
    }

    func upload(_ file: URL, as key: String) async throws {
        let response = try await HTTP.put(self.url(key), file: file, headers: self.headers)
        guard Self.successCodes.contains(response.status) else {
            throw RemoteStorageError(description: "uploading \(key): HTTP \(response.status)")
        }
    }

    /// GET, HEAD and PUT have no listing; the server's own expiry rules have to do.
    func list(prefix: String) async throws -> [RemoteObject] {
        throw RemoteStorageError(description: "\(self.base.absoluteString): an HTTP cache can't be listed; expire old files on the server, or use a directory or s3:// remote")
    }

    func delete(_ key: String) async throws {
        let response = try await HTTP.delete(self.url(key), headers: self.headers)
        guard Self.successCodes.contains(response.status) || response.status == Self.notFound else {
            throw RemoteStorageError(description: "deleting \(key): HTTP \(response.status)")
        }
    }

    /// 2xx: there; 404: not there; anything else (401, 403, …) is an error worth reporting.
    private static func found(_ status: Int, key: String) throws -> Bool {
        if Self.successCodes.contains(status) {
            return true
        }
        guard status == Self.notFound else {
            throw RemoteStorageError(description: "\(key): HTTP \(status)")
        }
        return false
    }
}

// MARK: - S3

/// Amazon S3 or a compatible service (Cloudflare R2, MinIO, …), signed with AWS Signature Version 4.
struct S3Storage: RemoteStorage {
    struct Credentials: Sendable {
        let accessKey: String
        let secretKey: String
        let sessionToken: String?
    }

    let bucket: String
    let prefix: String
    let region: String
    /// A compatible service's endpoint (path-style URLs); `nil` for AWS (virtual-hosted URLs).
    let endpoint: URL?
    let credentials: Credentials

    private enum SigV4 {
        static let algorithm = "AWS4-HMAC-SHA256"
        static let service = "s3"
        static let terminator = "aws4_request"
        static let unsignedPayload = "UNSIGNED-PAYLOAD"
        static let keyPrefix = "AWS4"
        static let dateTimeFormat = "yyyyMMdd'T'HHmmss'Z'"
        static let dateFormat = "yyyyMMdd"
        static let contentHashHeader = "x-amz-content-sha256"
        static let dateHeader = "x-amz-date"
        static let tokenHeader = "x-amz-security-token"
        static let hostHeader = "host"
    }

    private enum Method {
        static let get = "GET"
        static let head = "HEAD"
        static let put = "PUT"
        static let delete = "DELETE"
    }

    /// ListObjectsV2's parameters and the parts of its XML answer swx reads.
    private enum Listing {
        static let listType = "list-type"
        static let version = "2"
        static let prefix = "prefix"
        static let continuationToken = "continuation-token"
        static let contents = "Contents"
        static let key = "Key"
        static let size = "Size"
        static let lastModified = "LastModified"
        static let nextToken = "NextContinuationToken"
    }

    private static let notFound = 404
    private static let successCodes = 200..<300
    /// Characters left unencoded in an object path (RFC 3986 unreserved, plus `/`).
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
    /// Query values encode `/` too.
    private static let unreservedInQuery = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    func contains(_ key: String) async throws -> Bool {
        let (url, headers) = self.signed(Method.head, key: key)
        return try Self.found(try await HTTP.head(url, headers: headers), key: key)
    }

    func download(_ key: String, to file: URL) async throws -> Bool {
        let (url, headers) = self.signed(Method.get, key: key)
        return try Self.found(try await HTTP.download(url, headers: headers, to: file), key: key)
    }

    func upload(_ file: URL, as key: String) async throws {
        let (url, headers) = self.signed(Method.put, key: key)
        let response = try await HTTP.put(url, file: file, headers: headers)
        guard Self.successCodes.contains(response.status) else {
            let detail = String(decoding: response.body.prefix(300), as: UTF8.self)
            throw RemoteStorageError(description: "uploading \(key) to s3://\(self.bucket): HTTP \(response.status) \(detail)")
        }
    }

    /// ListObjectsV2, a page (up to 1000 keys) at a time.
    func list(prefix: String) async throws -> [RemoteObject] {
        let fullPrefix = self.prefix.isEmpty ? prefix : self.prefix + "/" + prefix
        var objects: [RemoteObject] = []
        var token: String?
        repeat {
            var query = [(Listing.listType, Listing.version), (Listing.prefix, fullPrefix)]
            if let token {
                query.append((Listing.continuationToken, token))
            }
            let (url, headers) = self.signed(Method.get, key: "", query: query)
            let response = try await HTTP.get(url, headers: headers)
            guard Self.successCodes.contains(response.status) else {
                let detail = String(decoding: response.body.prefix(300), as: UTF8.self)
                throw RemoteStorageError(description: "listing s3://\(self.bucket)/\(fullPrefix): HTTP \(response.status) \(detail)")
            }
            let page = Self.parseListing(String(decoding: response.body, as: UTF8.self))
            objects += page.objects.map { object in
                // Keys come back with the location's prefix; callers use their own.
                let key = self.prefix.isEmpty ? object.key : String(object.key.dropFirst(self.prefix.count + 1))
                return RemoteObject(key: key, bytes: object.bytes, modified: object.modified)
            }
            token = page.nextToken
        } while token != nil
        return objects
    }

    func delete(_ key: String) async throws {
        let (url, headers) = self.signed(Method.delete, key: key)
        let response = try await HTTP.delete(url, headers: headers)
        guard Self.successCodes.contains(response.status) || response.status == Self.notFound else {
            let detail = String(decoding: response.body.prefix(300), as: UTF8.self)
            throw RemoteStorageError(description: "deleting \(key) from s3://\(self.bucket): HTTP \(response.status) \(detail)")
        }
    }

    /// The objects of one ListObjectsV2 page and the token for the next. The answer is flat
    /// enough to read without an XML parser (FoundationXML isn't in the static Linux SDK).
    static func parseListing(_ xml: String) -> (objects: [RemoteObject], nextToken: String?) {
        let objects = Self.elements(Listing.contents, in: xml).compactMap { contents -> RemoteObject? in
            guard let key = Self.elements(Listing.key, in: contents).first else { return nil }
            let bytes = Self.elements(Listing.size, in: contents).first.flatMap { Int64($0) } ?? 0
            let modified = Self.elements(Listing.lastModified, in: contents).first.flatMap(Self.parseTimestamp) ?? .distantPast
            return RemoteObject(key: Self.unescapeXML(key), bytes: bytes, modified: modified)
        }
        return (objects, Self.elements(Listing.nextToken, in: xml).first.map(Self.unescapeXML))
    }

    /// The text of every `<name>…</name>` in `xml`.
    private static func elements(_ name: String, in xml: String) -> [String] {
        let open = "<\(name)>"
        let close = "</\(name)>"
        var values: [String] = []
        var remaining = xml[...]
        while let start = remaining.range(of: open), let end = remaining.range(of: close, range: start.upperBound..<remaining.endIndex) {
            values.append(String(remaining[start.upperBound..<end.lowerBound]))
            remaining = remaining[end.upperBound...]
        }
        return values
    }

    private static let xmlEntities = [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")]

    private static func unescapeXML(_ text: String) -> String {
        Self.xmlEntities.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    /// `2026-10-27T09:15:00.000Z`, with or without the fraction.
    private static func parseTimestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func found(_ status: Int, key: String) throws -> Bool {
        if Self.successCodes.contains(status) {
            return true
        }
        guard status == Self.notFound else {
            throw RemoteStorageError(description: "\(key): S3 answered HTTP \(status) (check credentials, region and bucket)")
        }
        return false
    }

    // MARK: Signing

    /// The object's URL and the headers that sign the request. An empty `key` addresses the
    /// bucket itself (listing), where the location's prefix goes in the query instead.
    func signed(_ method: String, key: String, query: [(String, String)] = [], date: Date = Date()) -> (URL, [String: String]) {
        let objectKey = key.isEmpty || self.prefix.isEmpty ? key : self.prefix + "/" + key
        let (objectURL, host, path) = self.location(of: objectKey)

        // SigV4 signs the query sorted by name, names and values strictly encoded.
        let canonicalQuery = query
            .map { (Self.encodeQuery($0.0), Self.encodeQuery($0.1)) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
        let url = canonicalQuery.isEmpty ? objectURL : URL(string: objectURL.absoluteString + "?" + canonicalQuery) ?? objectURL

        let amzDate = Self.format(date, SigV4.dateTimeFormat)
        let day = Self.format(date, SigV4.dateFormat)
        var headers = [SigV4.hostHeader: host, SigV4.contentHashHeader: SigV4.unsignedPayload, SigV4.dateHeader: amzDate]
        if let token = self.credentials.sessionToken {
            headers[SigV4.tokenHeader] = token
        }

        // Canonical request → string to sign → signature (AWS SigV4).
        let names = headers.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(headers[$0] ?? "")\n" }.joined()
        let signedHeaders = names.joined(separator: ";")
        let canonicalRequest = [method, path, canonicalQuery, canonicalHeaders, signedHeaders, SigV4.unsignedPayload].joined(separator: "\n")
        let scope = [day, self.region, SigV4.service, SigV4.terminator].joined(separator: "/")
        let stringToSign = [SigV4.algorithm, amzDate, scope, Self.hex(SHA256.hash(data: Data(canonicalRequest.utf8)))].joined(separator: "\n")

        var signingKey = SymmetricKey(data: Data((SigV4.keyPrefix + self.credentials.secretKey).utf8))
        for part in [day, self.region, SigV4.service, SigV4.terminator] {
            signingKey = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: signingKey)))
        }
        let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: signingKey))

        headers["Authorization"] = "\(SigV4.algorithm) Credential=\(self.credentials.accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        headers[SigV4.hostHeader] = nil  // URLSession sends Host itself, from the URL.
        return (url, headers)
    }

    /// Path-style on a custom endpoint, virtual-hosted on AWS.
    private func location(of objectKey: String) -> (url: URL, host: String, path: String) {
        let encodedKey = objectKey.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? objectKey
        if let endpoint = self.endpoint {
            let host = endpoint.host.map { host in endpoint.port.map { "\(host):\($0)" } ?? host } ?? ""
            let path = "/\(self.bucket)/\(encodedKey)"
            let url = URL(string: "\(endpoint.scheme ?? "https")://\(host)\(path)") ?? endpoint
            return (url, host, path)
        }
        let host = "\(self.bucket).s3.\(self.region).amazonaws.com"
        let path = "/\(encodedKey)"
        return (URL(string: "https://\(host)\(path)") ?? URL(fileURLWithPath: "/"), host, path)
    }

    private static func encodeQuery(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: Self.unreservedInQuery) ?? text
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
