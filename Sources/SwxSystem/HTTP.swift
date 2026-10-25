import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPError: Error, CustomStringConvertible {
    public let description: String
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
