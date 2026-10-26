import Foundation
import SwxCore
import SwxStore
import SwxSystem

/// Finds a package's repository URL from its name, through the Swift Package Index's package list.
public struct PackageIndex: Sendable {
    private static let listURL = URL(string: "https://raw.githubusercontent.com/SwiftPackageIndex/PackageList/main/packages.json")!
    private static let gitHubRepositories = "https://api.github.com/repos/"
    private static let gitHubHost = "github.com"
    private static let gitSuffix = ".git"
    private static let tokenVariable = "GITHUB_TOKEN"
    private static let maximumAge: TimeInterval = 24 * 60 * 60
    private static let httpOK = 200

    private enum Header {
        static let accept = "Accept"
        static let gitHubJSON = "application/vnd.github+json"
        static let authorization = "Authorization"
        static let bearer = "Bearer "
    }

    private let store: Store

    public init(store: Store) {
        self.store = store
    }

    /// Every listed URL whose repository is called `name` (case-insensitive).
    public func candidates(named name: String) async throws -> [String] {
        let wanted = name.lowercased()
        return try await self.packageURLs().filter { url in
            PackageIdentity.defaultName(fromLocation: url).lowercased() == wanted
        }
    }

    /// The original among same-named repositories: not a fork, most stars. `nil` when GitHub
    /// can't tell (rate limits, other hosts); the caller then asks for `owner/repo`.
    public func preferred(among candidates: [String]) async -> String? {
        guard candidates.count > 1 else { return candidates.first }

        var best: (url: String, stars: Int)?
        for url in candidates {
            guard let info = await self.repositoryInfo(url), !info.fork else { continue }
            if info.stars > best?.stars ?? -1 {
                best = (url, info.stars)
            }
        }
        return best?.url
    }

    // MARK: Package list

    /// The list, from the store when it's less than a day old.
    private func packageURLs() async throws -> [String] {
        let path = self.store.packageIndexPath
        let modified = (try? FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate]) as? Date
        if let modified, Date().timeIntervalSince(modified) < Self.maximumAge, let data = FileSystem.readIfPresent(path),
           let urls = try? JSONDecoder().decode([String].self, from: data) {
            return urls
        }

        let data = try await HTTP.data(from: Self.listURL)
        let urls = try JSONDecoder().decode([String].self, from: data)
        try FileSystem.writeAtomically(data, to: path)
        return urls
    }

    // MARK: GitHub

    private struct RepositoryInfo: Decodable {
        let fork: Bool
        let stars: Int

        enum CodingKeys: String, CodingKey {
            case fork
            case stars = "stargazers_count"
        }
    }

    private func repositoryInfo(_ url: String) async -> RepositoryInfo? {
        guard let components = URLComponents(string: url), components.host == Self.gitHubHost else { return nil }
        var path = components.path
        if path.hasSuffix(Self.gitSuffix) {
            path.removeLast(Self.gitSuffix.count)
        }
        guard let api = URL(string: Self.gitHubRepositories + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) else { return nil }

        // A token (CI usually has one) lifts GitHub's anonymous rate limit.
        var headers = [Header.accept: Header.gitHubJSON]
        if let token = ProcessInfo.processInfo.environment[Self.tokenVariable], !token.isEmpty {
            headers[Header.authorization] = Header.bearer + token
        }
        guard let response = try? await HTTP.get(api, headers: headers), response.status == Self.httpOK else { return nil }
        return try? JSONDecoder().decode(RepositoryInfo.self, from: response.body)
    }
}
