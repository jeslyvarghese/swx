import Crypto
import Foundation
import SwxSystem

/// Where a remote cache keeps its files: a key → bytes store.
public protocol RemoteStorage: Sendable {
    func contains(_ key: String) async throws -> Bool
    /// Downloads `key` to `file`; `false` when the remote doesn't have it.
    func download(_ key: String, to file: URL) async throws -> Bool
    func upload(_ file: URL, as key: String) async throws
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
        return true
    }

    /// Copied beside the destination, then renamed, so readers never see half a file.
    func upload(_ file: URL, as key: String) async throws {
        let destination = self.root.appendingPathComponent(key)
        try FileSystem.createDirectory(destination.deletingLastPathComponent())
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)")
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
    }

    private static let notFound = 404
    private static let successCodes = 200..<300
    /// Characters left unencoded in an object path (RFC 3986 unreserved, plus `/`).
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")

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

    /// The object's URL and the headers that sign the request.
    func signed(_ method: String, key: String, date: Date = Date()) -> (URL, [String: String]) {
        let objectKey = self.prefix.isEmpty ? key : self.prefix + "/" + key
        let (url, host, path) = self.location(of: objectKey)

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
        let canonicalRequest = [method, path, "", canonicalHeaders, signedHeaders, SigV4.unsignedPayload].joined(separator: "\n")
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
