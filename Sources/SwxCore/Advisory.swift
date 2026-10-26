/// A published vulnerability affecting a package (GitHub's advisory database, through OSV.dev).
public struct Advisory: Sendable, Equatable, Codable {
    public let id: String
    /// CVE and other identifiers of the same issue.
    public let aliases: [String]
    public let summary: String
    /// `LOW`, `MODERATE`, `HIGH`, `CRITICAL`; `nil` when unrated.
    public let severity: String?
    /// Versions of the package that fix it.
    public let fixedIn: [String]

    public init(id: String, aliases: [String], summary: String, severity: String?, fixedIn: [String]) {
        self.id = id
        self.aliases = aliases
        self.summary = summary
        self.severity = severity
        self.fixedIn = fixedIn
    }
}
