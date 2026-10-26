import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPError: Error, CustomStringConvertible {
    public let description: String

    public init(description: String) {
        self.description = description
    }
}

/// A response whose status the caller interprets (registries answer 404 for unknown packages).
public struct HTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    private let headers: [String: String]

    init(status: Int, body: Data, headers: [String: String]) {
        self.status = status
        self.body = body
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    /// Header lookup is case-insensitive, as HTTP's is.
    public func header(_ name: String) -> String? {
        self.headers[name.lowercased()]
    }
}

/// HTTP downloads through URLSession, so no `curl` executable is needed
/// (the official Swift Linux images don't ship one; SwiftPM uses libcurl the same way).
public enum HTTP {
    private static let attempts = 3
    private static let successCodes = 200..<300
    private static let serverErrorCodes = 500..<600
    private static let retryDelay: Duration = .seconds(1)

    /// The body of `url`, held in memory (small documents such as release lists).
    public static func data(from url: URL) async throws -> Data {
        try await Self.retrying(url) {
            let (data, response) = try await Self.session.data(from: url)
            try Self.check(response, for: url)
            return data
        }
    }

    /// Downloads `url` to `destination`, replacing any file there.
    public static func download(_ url: URL, to destination: URL) async throws {
        try await Self.retrying(url) {
            let (temporary, response) = try await Self.session.download(from: url)
            try Self.check(response, for: url)

            // The temporary file is ours to move; put it next to its final name.
            try FileSystem.createDirectory(destination.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    /// A GET whose status is returned rather than checked; retries only server and network errors.
    public static func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        try await Self.retrying(url) {
            var request = URLRequest(url: url)
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            let (data, response) = try await Self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw HTTPError(description: "\(url.absoluteString): not an HTTP response")
            }
            if Self.serverErrorCodes.contains(http.statusCode) {
                throw Failure.transient(HTTPError(description: "\(url.absoluteString): HTTP \(http.statusCode)"))
            }
            var fields: [String: String] = [:]
            for case (let name as String, let value as String) in http.allHeaderFields {
                fields[name] = value
            }
            return HTTPResponse(status: http.statusCode, body: data, headers: fields)
        }
    }

    /// A POST whose status is returned rather than checked (OCSP queries).
    public static func post(_ url: URL, body: Data, headers: [String: String]) async throws -> HTTPResponse {
        try await Self.retrying(url) {
            var request = URLRequest(url: url)
            request.httpMethod = Self.postMethod
            request.httpBody = body
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            let (data, response) = try await Self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw HTTPError(description: "\(url.absoluteString): not an HTTP response")
            }
            return HTTPResponse(status: http.statusCode, body: data, headers: [:])
        }
    }

    private static let postMethod = "POST"
    private static let putMethod = "PUT"
    private static let headMethod = "HEAD"

    /// The status of a HEAD request (existence checks); retries only server and network errors.
    public static func head(_ url: URL, headers: [String: String]) async throws -> Int {
        try await Self.retrying(url) {
            var request = URLRequest(url: url)
            request.httpMethod = Self.headMethod
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            let (_, response) = try await Self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw HTTPError(description: "\(url.absoluteString): not an HTTP response")
            }
            if Self.serverErrorCodes.contains(http.statusCode) {
                throw Failure.transient(HTTPError(description: "\(url.absoluteString): HTTP \(http.statusCode)"))
            }
            return http.statusCode
        }
    }

    /// Uploads a file's bytes; the status is returned rather than checked.
    public static func put(_ url: URL, file: URL, headers: [String: String]) async throws -> HTTPResponse {
        try await Self.retrying(url) {
            var request = URLRequest(url: url)
            request.httpMethod = Self.putMethod
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            let (data, response) = try await Self.session.upload(for: request, fromFile: file)
            guard let http = response as? HTTPURLResponse else {
                throw HTTPError(description: "\(url.absoluteString): not an HTTP response")
            }
            if Self.serverErrorCodes.contains(http.statusCode) {
                throw Failure.transient(HTTPError(description: "\(url.absoluteString): HTTP \(http.statusCode)"))
            }
            return HTTPResponse(status: http.statusCode, body: data, headers: [:])
        }
    }

    /// Downloads `url` to `destination` with request headers; returns the status, and leaves
    /// `destination` alone unless it is a success.
    public static func download(_ url: URL, headers: [String: String], to destination: URL) async throws -> Int {
        try await Self.retrying(url) {
            var request = URLRequest(url: url)
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            let (temporary, response) = try await Self.session.download(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw HTTPError(description: "\(url.absoluteString): not an HTTP response")
            }
            if Self.serverErrorCodes.contains(http.statusCode) {
                throw Failure.transient(HTTPError(description: "\(url.absoluteString): HTTP \(http.statusCode)"))
            }
            guard Self.successCodes.contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: temporary)
                return http.statusCode
            }
            try FileSystem.createDirectory(destination.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return http.statusCode
        }
    }

    // MARK: Helpers

    private static let session = URLSession(configuration: .ephemeral)

    /// Whether a failure is worth another attempt.
    private enum Failure: Error {
        case transient(Error)
    }

    private static func check(_ response: URLResponse, for url: URL) throws {
        guard let status = (response as? HTTPURLResponse)?.statusCode else { return }
        if Self.serverErrorCodes.contains(status) {
            throw Failure.transient(HTTPError(description: "\(url.absoluteString): HTTP \(status)"))
        }
        guard Self.successCodes.contains(status) else {
            throw HTTPError(description: "\(url.absoluteString): HTTP \(status)")
        }
    }

    /// Retries network errors and server errors; client errors (404, …) fail at once.
    private static func retrying<T>(_ url: URL, _ operation: () async throws -> T) async throws -> T {
        var lastError: Error = HTTPError(description: "\(url.absoluteString): no attempt made")
        for attempt in 1...Self.attempts {
            do {
                Trace.event("http \(url.absoluteString)")
                return try await operation()
            } catch Failure.transient(let error) {
                lastError = error
            } catch let error as HTTPError {
                throw error
            } catch {
                lastError = HTTPError(description: "\(url.absoluteString): \(error.localizedDescription)")
            }
            guard attempt < Self.attempts else { break }
            try await Task.sleep(for: Self.retryDelay)
        }
        throw lastError
    }
}
