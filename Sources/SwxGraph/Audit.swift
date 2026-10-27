import Foundation
import SwxCore

/// How `swx audit` prints its report.
public enum AuditFormat: Sendable {
    case text
    case json
}

/// One vulnerable package and what affects it.
public struct AuditFinding: Sendable, Equatable, Encodable {
    public let package: String
    public let version: String
    public let advisories: [Advisory]

    public init(package: String, version: String, advisories: [Advisory]) {
        self.package = package
        self.version = version
        self.advisories = advisories
    }
}

/// GitHub's advisory severities, mildest first.
public enum AdvisorySeverity: String, Sendable, CaseIterable, Comparable, Codable {
    case low
    case moderate
    case high
    case critical

    /// OSV spells GitHub's ratings in capitals; some databases say MEDIUM for MODERATE.
    private static let medium = "medium"

    public init?(rating: String) {
        let lowered = rating.lowercased()
        self.init(rawValue: lowered == Self.medium ? Self.moderate.rawValue : lowered)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (Self.allCases.firstIndex(of: lhs) ?? Self.allCases.startIndex) < (Self.allCases.firstIndex(of: rhs) ?? Self.allCases.startIndex)
    }
}

/// Which advisories `swx audit` accepts: ignored ones, and those below a severity.
public struct AuditPolicy: Sendable, Equatable {
    /// Advisory ids or aliases (`GHSA-…`, `CVE-…`) not to report.
    public var ignore: Set<String>
    /// The mildest severity that fails the audit. Unrated advisories always fail.
    public var failOn: AdvisorySeverity

    public init(ignore: Set<String> = [], failOn: AdvisorySeverity = .low) {
        self.ignore = ignore
        self.failOn = failOn
    }

    func ignores(_ advisory: Advisory) -> Bool {
        self.ignore.contains(advisory.id) || advisory.aliases.contains(where: self.ignore.contains)
    }

    func fails(_ advisory: Advisory) -> Bool {
        guard let severity = advisory.severity.flatMap(AdvisorySeverity.init(rating:)) else { return true }
        return severity >= self.failOn
    }
}

/// An advisory the policy ignores, still named in the report so it isn't forgotten.
public struct IgnoredAdvisory: Sendable, Equatable, Encodable {
    public let package: String
    public let id: String
}

/// `swx audit`'s answer.
public struct AuditReport: Sendable, Equatable, Encodable {
    public let findings: [AuditFinding]
    /// Versioned git packages that were checked.
    public let checked: Int
    /// Packages OSV can't be asked about: branches, revisions, paths, registry packages.
    public let unchecked: [String]
    public let ignored: [IgnoredAdvisory]
    /// Whether any reported advisory is as severe as the policy's threshold.
    public let failed: Bool

    public init(findings: [AuditFinding], checked: Int, unchecked: [String], policy: AuditPolicy = AuditPolicy()) {
        var kept: [AuditFinding] = []
        var ignored: [IgnoredAdvisory] = []
        for finding in findings {
            let skipped = finding.advisories.filter(policy.ignores)
            let reported = finding.advisories.filter { !policy.ignores($0) }
            ignored += skipped.map { IgnoredAdvisory(package: finding.package, id: $0.id) }
            if !reported.isEmpty {
                kept.append(AuditFinding(package: finding.package, version: finding.version, advisories: reported))
            }
        }
        self.findings = kept
        self.checked = checked
        self.unchecked = unchecked
        self.ignored = ignored
        self.failed = kept.contains { $0.advisories.contains(where: policy.fails) }
    }

    public var isVulnerable: Bool {
        !self.findings.isEmpty
    }

    public func render(_ format: AuditFormat) -> String {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self) + "\n"
        case .text:
            return self.text()
        }
    }

    private static let cvePrefix = "CVE-"

    /// `GHSA-… (CVE-…) HIGH: summary`, then `fixed in …`.
    static func describe(_ advisory: Advisory) -> [String] {
        // CVE ids only: distributions add their own aliases by the dozen (JSON keeps them all).
        let cves = advisory.aliases.filter { $0.hasPrefix(Self.cvePrefix) }
        let aliases = cves.isEmpty ? "" : " (\(cves.joined(separator: ", ")))"
        let severity = advisory.severity.map { " \($0)" } ?? ""
        var lines = ["\(advisory.id)\(aliases)\(severity): \(advisory.summary)"]
        lines.append(advisory.fixedIn.isEmpty ? "  no fixed version yet" : "  fixed in \(advisory.fixedIn.joined(separator: ", "))")
        return lines
    }

    /// Each vulnerable package with its advisories, then a verdict.
    private func text() -> String {
        var output = ""
        for finding in self.findings {
            output += "\(finding.package) \(finding.version)\n"
            for advisory in finding.advisories {
                output += Self.describe(advisory).map { "  " + $0 + "\n" }.joined()
            }
            output += "\n"
        }

        let count = self.findings.reduce(0) { $0 + $1.advisories.count }
        let packages = self.checked == 1 ? "1 package" : "\(self.checked) packages"
        output += count == 0
            ? "no known vulnerabilities in \(packages) (OSV.dev)\n"
            : "\(count) known \(count == 1 ? "vulnerability" : "vulnerabilities") in \(self.findings.count) of \(packages) (OSV.dev)\n"
        if !self.unchecked.isEmpty {
            output += "not checked (no released version on a git host): \(self.unchecked.joined(separator: ", "))\n"
        }
        if !self.ignored.isEmpty {
            output += "ignored by policy: \(self.ignored.map { "\($0.id) (\($0.package))" }.joined(separator: ", "))\n"
        }
        if self.isVulnerable && !self.failed {
            output += "all below the policy's failing severity\n"
        }
        return output
    }
}
