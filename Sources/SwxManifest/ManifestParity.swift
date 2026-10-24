import Foundation

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

/// Differential testing of `StaticManifestParser` against `swift package dump-package`.
public enum ManifestParity {
    public static func check(_ contents: String, environment: CompilationEnvironment) async -> ParityOutcome {
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
