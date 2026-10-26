import Foundation
import SwxCore
import SwxManifest

/// How `swx outdated` prints its report.
public enum OutdatedFormat: Sendable {
    case text
    case json
}

/// Which packages `swx outdated` lists.
public enum OutdatedScope: Sendable {
    /// Only packages with a newer version.
    case outdated
    /// Every dependency.
    case all
}

/// One dependency's versions: what is pinned, what the requirements allow, what exists.
public struct OutdatedEntry: Sendable, Equatable, Encodable {
    public let package: String
    /// A version, a branch or a short commit.
    public let current: String
    /// The newest version every requirement in the graph allows (what an update would pick
    /// unless other constraints change); `nil` for branches, revisions and unknown versions.
    public let wanted: String?
    /// The newest release (pre-releases only when the current version is one).
    public let latest: String?
    /// The packages that require it (`root` for the root).
    public let dependents: [String]

    public var isOutdated: Bool {
        guard let latest else { return false }
        return latest != self.current
    }
}

extension PackageGraph {
    private static let rootDependent = "root"

    /// Every requirement on each package in the graph, with the package that states it.
    public func requirements() -> [String: [(dependent: String, requirement: Requirement)]] {
        var requirements: [String: [(String, Requirement)]] = [:]
        for package in self.reachablePackages {
            let required = Set(self.dependencies[package.identity] ?? [])
            let dependent = package.role == .root ? Self.rootDependent : package.identity
            for dependency in package.manifest.dependencies {
                guard let target = self.package(satisfying: dependency, declaredBy: package), required.contains(target.identity) else { continue }
                requirements[target.identity, default: []].append((dependent, dependency.declaration.requirement))
            }
        }
        return requirements
    }

    /// The report entry for one package, given the versions that exist upstream and the
    /// requirements on it (from `requirements()`).
    public func outdatedEntry(
        for package: GraphPackage,
        available: [Version],
        requirements: [(dependent: String, requirement: Requirement)]
    ) -> OutdatedEntry {
        let current = package.version.flatMap { Version($0) }

        // Wanted: allowed by every version requirement. Branch and revision pins have no "wanted".
        var wanted: Version?
        if current != nil {
            wanted = available.filter { version in
                requirements.allSatisfy { entry in
                    guard case .version(let range) = entry.requirement else { return true }
                    return range.contains(version)
                }
            }.max()
        }

        // Latest: stable releases, unless the package is already on a pre-release.
        let allowsPrereleases = current?.hasPrerelease == true
        let latest = available.filter { allowsPrereleases || !$0.hasPrerelease }.max()

        return OutdatedEntry(
            package: package.identity,
            current: package.pinned ?? package.path,
            wanted: wanted?.description,
            latest: latest?.description,
            dependents: requirements.map(\.dependent)
        )
    }
}

extension [OutdatedEntry] {
    private enum Column {
        static let titles = ["Package", "Current", "Wanted", "Latest", "Dependents"]
        static let gap = 2
        static let none = "-"
        static let separator = ", "
    }

    public func render(_ format: OutdatedFormat, scope: OutdatedScope) -> String {
        let shown = scope == .all ? self : self.filter(\.isOutdated)
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return String(decoding: (try? encoder.encode(shown)) ?? Data(), as: UTF8.self) + "\n"
        case .text:
            return Self.table(shown, total: self.count, outdated: self.filter(\.isOutdated).count)
        }
    }

    private static func table(_ entries: [OutdatedEntry], total: Int, outdated: Int) -> String {
        let dependencies = total == 1 ? "1 dependency" : "\(total) dependencies"
        let updatable = entries.filter { $0.wanted != nil && $0.wanted != $0.current }.count
        let advice = updatable > 0
            ? "`swx package update` moves \(updatable) to Wanted"
            : "newer ones need wider requirements in Package.swift"
        let summary = outdated == 0
            ? "\(dependencies), all on their latest versions\n"
            : "\(outdated) of \(dependencies) have newer versions; \(advice)\n"
        guard !entries.isEmpty else { return summary }

        // Aligned columns, sized to their widest cell.
        let rows = [Column.titles] + entries.map {
            [$0.package, $0.current, $0.wanted ?? Column.none, $0.latest ?? Column.none, $0.dependents.joined(separator: Column.separator)]
        }
        let widths = (0..<Column.titles.count).map { column in rows.map { $0[column].count }.max() ?? 0 }
        let lines = rows.map { row in
            row.enumerated().map { column, cell in
                column == row.count - 1 ? cell : cell.padding(toLength: widths[column] + Column.gap, withPad: " ", startingAt: 0)
            }.joined()
        }
        return lines.joined(separator: "\n") + "\n\n" + summary
    }
}
