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

/// `swx audit`'s answer.
public struct AuditReport: Sendable, Equatable, Encodable {
    public let findings: [AuditFinding]
    /// Versioned git packages that were checked.
    public let checked: Int
    /// Packages OSV can't be asked about: branches, revisions, paths, registry packages.
    public let unchecked: [String]

    public init(findings: [AuditFinding], checked: Int, unchecked: [String]) {
        self.findings = findings
        self.checked = checked
        self.unchecked = unchecked
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
        return output
    }
}
