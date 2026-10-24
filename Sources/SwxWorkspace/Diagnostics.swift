import Foundation
import SwxCore
import SwxManifest
import SwxSource
import SwxStore
import SwxSystem

/// Aggregate result of comparing the static manifest parser with real evaluation.
public struct ManifestParityReport: Sendable {
    public var matched = 0
    public var declined = 0
    /// Decline reasons, most common first.
    public var declineReasons: [(String, Int)] = []
    public var evaluationFailed = 0
    /// `(revision, explanation)` for each disagreement.
    public var mismatches: [(String, String)] = []

    public var checked: Int {
        self.matched + self.declined + self.evaluationFailed + self.mismatches.count
    }
}

/// Maintenance and verification commands that operate on the shared store.
public struct Diagnostics: Sendable {
    private let store: Store
    private let maximumConcurrency: Int

    public init(cacheDirectory: URL?, maximumConcurrency: Int) {
        self.store = cacheDirectory.map(Store.init(root:)) ?? Store.default()
        self.maximumConcurrency = maximumConcurrency
    }

    /// Runs every manifest seen by past resolutions through both the parser and `dump-package`.
    public func manifestParity(limit: Int?) async throws -> ManifestParityReport {
        let toolchain = try await Toolchain.detect()
        let source = GitSource(store: self.store, maximumConcurrency: self.maximumConcurrency)

        // Pick the manifest SwiftPM would load at each cached revision.
        var corpus: [(String, String)] = []
        for files in source.cachedManifestFiles() {
            guard let name = ToolsVersion.selectManifest(fileNames: files.rootFileNames, current: toolchain.toolsVersion, contentsOf: { files.files[$0] }),
                  let contents = files.files[name] else { continue }
            corpus.append((files.revision, contents))
        }

        // Duplicate manifests across revisions only need checking once.
        var seen: Set<String> = []
        corpus = corpus.filter { seen.insert($0.1).inserted }
        if let limit {
            corpus = Array(corpus.prefix(limit))
        }

        // Evaluate in parallel, bounded like any other subprocess fan-out.
        let limiter = ConcurrencyLimiter(limit: self.maximumConcurrency)
        let environment = CompilationEnvironment.host(compilerVersion: toolchain.toolsVersion)
        let outcomes = await withTaskGroup(of: (String, ParityOutcome).self) { group in
            for (revision, contents) in corpus {
                group.addTask { (revision, await limiter.run { await ManifestParity.check(contents, environment: environment) }) }
            }
            return await group.reduce(into: [(String, ParityOutcome)]()) { $0.append($1) }
        }

        var report = ManifestParityReport()
        var reasons: [String: Int] = [:]
        for (revision, outcome) in outcomes {
            switch outcome {
            case .matched:
                report.matched += 1
            case .declined(let reason):
                report.declined += 1
                reasons[reason, default: 0] += 1
            case .evaluationFailed:
                report.evaluationFailed += 1
            case .mismatched(let parsed, let evaluated):
                report.mismatches.append((revision, Self.explain(parsed, evaluated)))
            }
        }
        report.declineReasons = reasons.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        return report
    }

    /// The first differing field, for a readable report.
    private static func explain(_ parsed: Manifest, _ evaluated: Manifest) -> String {
        if parsed.name != evaluated.name { return "name: \(parsed.name) vs \(evaluated.name)" }
        if parsed.toolsVersion != evaluated.toolsVersion { return "toolsVersion: \(parsed.toolsVersion) vs \(evaluated.toolsVersion)" }
        if parsed.dependencies != evaluated.dependencies { return "dependencies:\n  static:    \(parsed.dependencies)\n  evaluated: \(evaluated.dependencies)" }
        if parsed.products != evaluated.products { return "products:\n  static:    \(parsed.products)\n  evaluated: \(evaluated.products)" }
        if parsed.traits != evaluated.traits { return "traits:\n  static:    \(parsed.traits)\n  evaluated: \(evaluated.traits)" }
        for (left, right) in zip(parsed.targets, evaluated.targets) where left != right {
            return "target \(left.name):\n  static:    \(left)\n  evaluated: \(right)"
        }
        return "targets: \(parsed.targets.map(\.name)) vs \(evaluated.targets.map(\.name))"
    }
}
