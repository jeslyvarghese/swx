import Foundation
import SwxCore
import SwxSystem

/// How the static parser compares with real evaluation for one manifest.
public enum ParityOutcome: Sendable {
    /// Both agree exactly.
    case matched
    /// The static parser declined; the manifest would be evaluated (correct, just slower).
    case declined(reason: String)
    /// Both produced a manifest, but they differ: a static-parser bug.
    case mismatched(staticResult: Manifest, evaluated: Manifest)
    /// Real evaluation failed (e.g. too new for this toolchain); nothing to compare.
    case evaluationFailed(String)
}

/// What is compared against `swift package dump-package`.
public enum ParityCandidate: Sendable {
    /// The static parser (`StaticManifestParser`).
    case staticParser
    /// Compiling against Xcode's ManifestAPI (`XcodeManifestEvaluator`), as used for app manifests.
    case xcodeManifestAPI
}

/// Differential testing of manifest readers against `swift package dump-package`.
public enum ManifestParity {
    private static let scratchPrefix = "swx-parity"

    public static func check(_ contents: String, environment: CompilationEnvironment, candidate: ParityCandidate) async -> ParityOutcome {
        switch candidate {
        case .staticParser:
            return await Self.checkStaticParser(contents, environment: environment)
        case .xcodeManifestAPI:
            return await Self.checkXcodeEvaluator(contents)
        }
    }

    /// Both evaluations run in one scratch package, so relative paths resolve identically.
    private static func checkXcodeEvaluator(_ contents: String) async -> ParityOutcome {
        do {
            let directory = try FileSystem.makeTemporaryDirectory(prefix: Self.scratchPrefix)
            defer { try? FileSystem.removeTree(directory) }
            try Data(contents.utf8).write(to: directory.appendingPathComponent(WellKnownFile.manifest))

            let evaluated: Manifest
            do {
                evaluated = try await ManifestLoader.runDumpPackageDecoding(at: directory)
            } catch {
                return .evaluationFailed(String(describing: error))
            }
            let candidate = try await XcodeManifestEvaluator.evaluate(contents: contents, packageDirectory: directory)
            return candidate == evaluated ? .matched : .mismatched(staticResult: candidate, evaluated: evaluated)
        } catch {
            return .declined(reason: "Xcode evaluation failed: \(String(describing: error).prefix(160))")
        }
    }

    private static func checkStaticParser(_ contents: String, environment: CompilationEnvironment) async -> ParityOutcome {
        let parsed: Manifest
        switch StaticManifestParser.analyze(contents, environment: environment) {
        case .success(let manifest):
            parsed = manifest
        case .failure(let decline):
            return .declined(reason: decline.description)
        }
        do {
            let evaluated = try await ManifestLoader.evaluate(contents: contents)
            return parsed == evaluated ? .matched : .mismatched(staticResult: parsed, evaluated: evaluated)
        } catch {
            return .evaluationFailed(String(describing: error))
        }
    }
}
