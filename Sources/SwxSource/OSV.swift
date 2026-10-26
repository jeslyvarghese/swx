import Foundation
import SwxCore
import SwxSystem

/// OSV.dev's API: which advisories affect a package version, and what they say.
public enum OSV {
    private static let batchURL = URL(string: "https://api.osv.dev/v1/querybatch")!
    private static let vulnerabilityURL = "https://api.osv.dev/v1/vulns/"
    private static let ecosystem = "SwiftURL"
    private static let httpOK = 200
    private static let jsonHeaders = ["Content-Type": "application/json"]

    /// OSV's JSON fields.
    private enum Key {
        static let queries = "queries"
        static let results = "results"
        static let package = "package"
        static let ecosystem = "ecosystem"
        static let name = "name"
        static let version = "version"
        static let vulnerabilities = "vulns"
        static let id = "id"
        static let affected = "affected"
        static let ranges = "ranges"
        static let events = "events"
        static let fixed = "fixed"
        static let aliases = "aliases"
        static let summary = "summary"
        static let details = "details"
        static let databaseSpecific = "database_specific"
        static let severity = "severity"
    }

    private enum URLPart {
        static let schemeSeparator = "://"
        static let sshUser = "git@"
        static let sshPathSeparator = ":"
        static let userSeparator: Character = "@"
        static let pathSeparator: Character = "/"
        static let gitSuffix = ".git"
    }

    /// OSV's name for a git package, `github.com/owner/repo`, from any spelling of its URL
    /// (`https://…`, `https://user@…`, `git@host:owner/repo.git`). `nil` for things that aren't URLs.
    public static func packageName(forURL url: String) -> String? {
        var text = url

        // Drop the scheme, or turn scp-style SSH into a path.
        if let scheme = text.range(of: URLPart.schemeSeparator) {
            text = String(text[scheme.upperBound...])
        } else if text.hasPrefix(URLPart.sshUser) {
            text = String(text.dropFirst(URLPart.sshUser.count)).replacingOccurrences(of: URLPart.sshPathSeparator, with: String(URLPart.pathSeparator))
        }

        // Drop credentials before the host, then trailing slashes and `.git`.
        let host = text.prefix { $0 != URLPart.pathSeparator }
        if let at = host.lastIndex(of: URLPart.userSeparator) {
            text = String(text[text.index(after: at)...])
        }
        while text.last == URLPart.pathSeparator {
            text.removeLast()
        }
        if text.hasSuffix(URLPart.gitSuffix) {
            text.removeLast(URLPart.gitSuffix.count)
        }
        return text.contains(URLPart.pathSeparator) ? text : nil
    }

    /// Advisory ids affecting each `(name, version)`, in order. Names are tried as given and
    /// lower-cased, since OSV matches them exactly and manifests don't always use GitHub's case.
    public static func advisoryIDs(for packages: [(name: String, version: String)]) async throws -> [[String]] {
        guard !packages.isEmpty else { return [] }

        // Each package once as written, once lower-cased (when that differs).
        var queries: [[String: Any]] = []
        var owners: [Int] = []
        for (index, package) in packages.enumerated() {
            for name in Set([package.name, package.name.lowercased()]) {
                queries.append([Key.package: [Key.ecosystem: Self.ecosystem, Key.name: name], Key.version: package.version])
                owners.append(index)
            }
        }

        let body = try JSONSerialization.data(withJSONObject: [Key.queries: queries])
        let response = try await HTTP.post(Self.batchURL, body: body, headers: Self.jsonHeaders)
        guard response.status == Self.httpOK,
              let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let results = json[Key.results] as? [[String: Any]], results.count == queries.count else {
            throw HTTPError(description: "OSV.dev answered HTTP \(response.status)")
        }

        var ids = Array(repeating: [String](), count: packages.count)
        for (result, owner) in zip(results, owners) {
            for vulnerability in result[Key.vulnerabilities] as? [[String: Any]] ?? [] {
                guard let id = vulnerability[Key.id] as? String, !ids[owner].contains(id) else { continue }
                ids[owner].append(id)
            }
        }
        return ids.map { $0.sorted() }
    }

    /// One advisory's details; `fixedIn` lists the versions that fix it for `packageName`.
    public static func advisory(_ id: String, packageName: String) async throws -> Advisory {
        guard let url = URL(string: Self.vulnerabilityURL + id) else {
            throw HTTPError(description: "invalid advisory id \(id)")
        }
        let data = try await HTTP.data(from: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HTTPError(description: "OSV.dev returned no advisory for \(id)")
        }

        // Fixed versions come from the ranges of this package's entry.
        var fixed: [String] = []
        for affected in json[Key.affected] as? [[String: Any]] ?? [] {
            let name = (affected[Key.package] as? [String: Any])?[Key.name] as? String
            guard name?.lowercased() == packageName.lowercased() else { continue }
            for range in affected[Key.ranges] as? [[String: Any]] ?? [] {
                for event in range[Key.events] as? [[String: Any]] ?? [] {
                    if let version = event[Key.fixed] as? String, !fixed.contains(version) {
                        fixed.append(version)
                    }
                }
            }
        }

        return Advisory(
            id: id,
            aliases: json[Key.aliases] as? [String] ?? [],
            summary: json[Key.summary] as? String ?? json[Key.details] as? String ?? "",
            severity: (json[Key.databaseSpecific] as? [String: Any])?[Key.severity] as? String,
            fixedIn: fixed
        )
    }
}
