import Foundation
import SwxCore
import SwxSystem

/// A commit's `Package.swift` read over plain HTTP where the host serves raw files (GitHub),
/// long before a blobless clone could provide it. Only a hint, to start fetching the next level
/// of the graph early: the manifests resolution uses still come from git.
public enum ManifestHints {
    private static let gitHubHost = "github.com"
    private static let rawBase = "https://raw.githubusercontent.com"
    private static let gitSuffix = ".git"
    private static let ok = 200

    /// `SWX_MANIFEST_HINTS=0` turns hints off.
    private static let variable = "SWX_MANIFEST_HINTS"
    private static let disabled = "0"

    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[Self.variable] != Self.disabled
    }

    /// The manifest at `revision`, or `nil` when the host can't serve it this way.
    public static func manifest(url: String, revision: String) async -> String? {
        guard let raw = Self.rawURL(url: url, revision: revision),
              let response = try? await HTTP.get(raw, headers: [:]), response.status == Self.ok else {
            return nil
        }
        return String(decoding: response.body, as: UTF8.self)
    }

    /// `https://github.com/owner/repo(.git)` → its raw `Package.swift` at `revision`.
    static func rawURL(url: String, revision: String) -> URL? {
        guard let components = URLComponents(string: url), components.host?.lowercased() == Self.gitHubHost else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        let repository = parts[1].hasSuffix(Self.gitSuffix) ? String(parts[1].dropLast(Self.gitSuffix.count)) : parts[1]
        return URL(string: [Self.rawBase, parts[0], repository, revision, WellKnownFile.manifest].joined(separator: "/"))
    }
}
