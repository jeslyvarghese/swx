/// The `// swift-tools-version:` of a manifest.
public struct ToolsVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let version: Version

    public init(_ major: Int, _ minor: Int, _ patch: Int = 0) {
        self.version = Version(major, minor, patch)
    }

    public init(version: Version) {
        self.version = version.withoutPrerelease
    }

    /// Manifests without a tools-version comment are treated as Swift 3.1 (SwiftPM's documented default).
    public static let v3 = ToolsVersion(3, 1, 0)
    public static let v4 = ToolsVersion(4, 0, 0)
    /// `Package.resolved` v2 is written from 5.6.
    public static let v5_6 = ToolsVersion(5, 6, 0)
    /// `Package.resolved` v3 is written above 5.9.
    public static let v5_9 = ToolsVersion(5, 9, 0)

    /// `[@swift-X.Y.Z, @swift-X.Y, @swift-X]`, most specific first.
    public var versionSpecificKeys: [String] {
        let version = self.version
        return [
            "@swift-\(version.major).\(version.minor).\(version.patch)",
            "@swift-\(version.major).\(version.minor)",
            "@swift-\(version.major)",
        ]
    }

    public var description: String {
        self.version.description
    }

    public static func < (lhs: ToolsVersion, rhs: ToolsVersion) -> Bool {
        lhs.version < rhs.version
    }
}

// MARK: - Parsing the tools-version comment

extension ToolsVersion {
    private static let commentMarker = "//"
    private static let label = "swift-tools-version"
    private static let separators: Set<Character> = [":", " ", "\t"]
    private static let terminators: Set<Character> = [";", " ", "\t", "\r"]

    /// Parses the first line of a manifest. Returns `.v3` when the line is not a tools-version comment.
    ///
    /// Accepts the spellings SwiftPM accepts in practice: `// swift-tools-version:5.9`,
    /// `// swift-tools-version: 6.0`, `//swift-tools-version:5.3.1`, and two-component versions.
    public static func parse(manifest contents: String) -> ToolsVersion {
        // Only the first line matters.
        let firstLine = contents.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        var line = Substring(firstLine)

        // Expect `//`, optional whitespace, then the label (case-insensitive).
        guard line.hasPrefix(Self.commentMarker) else {
            return .v3
        }
        line = line.dropFirst(Self.commentMarker.count).drop(while: { $0 == " " || $0 == "\t" })
        guard line.lowercased().hasPrefix(Self.label) else {
            return .v3
        }
        line = line.dropFirst(Self.label.count).drop(while: { Self.separators.contains($0) })

        // The version runs until a terminator (`;` begins optional settings).
        let versionText = line.prefix(while: { !Self.terminators.contains($0) })
        return Self.parse(versionText: String(versionText)) ?? .v3
    }

    /// Parses `X.Y` or `X.Y.Z`.
    public static func parse(versionText: String) -> ToolsVersion? {
        let parts = versionText.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, (2...3).contains(numbers.count) else {
            return nil
        }
        return ToolsVersion(numbers[0], numbers[1], numbers.count == 3 ? numbers[2] : 0)
    }
}

// MARK: - Choosing the manifest file

/// Well-known file and directory names shared with SwiftPM.
public enum WellKnownFile {
    public static let manifest = "Package.swift"
    public static let manifestBaseName = "Package"
    public static let swiftExtension = ".swift"
    public static let versionSpecificPrefix = "Package@swift-"
    public static let packageResolved = "Package.resolved"
    public static let buildDirectory = ".build"
    public static let checkoutsDirectory = "checkouts"
    public static let workspaceState = "workspace-state.json"
}

extension ToolsVersion {
    /// Picks the manifest SwiftPM would load, given the files at the package root.
    ///
    /// Pure version of `ManifestLoader.findManifest`. `contentsOf` returns a file's text.
    public static func selectManifest(
        fileNames: [String],
        current: ToolsVersion,
        contentsOf: (String) -> String?
    ) -> String? {
        let names = Set(fileNames)

        // 1. An exact version-specific key for the running toolchain wins outright.
        for key in current.versionSpecificKeys {
            let candidate = WellKnownFile.manifestBaseName + key + WellKnownFile.swiftExtension
            if names.contains(candidate) {
                return candidate
            }
        }

        // 2. Collect other version-specific manifests.
        var versionSpecific: [ToolsVersion: String] = [:]
        for name in fileNames {
            guard let version = Self.versionSpecificManifestVersion(fileName: name) else { continue }
            versionSpecific[version] = name
        }
        let hasRegular = names.contains(WellKnownFile.manifest)
        let regularVersion = hasRegular ? Self.parse(manifest: contentsOf(WellKnownFile.manifest) ?? "") : .v3

        // 3. Without a compatible version-specific manifest, use the regular one.
        guard let candidateVersion = versionSpecific.keys.sorted(by: >).first(where: { $0 <= current }),
              let candidate = versionSpecific[candidateVersion] else {
            return hasRegular ? WellKnownFile.manifest : nil
        }

        // 4. Prefer whichever declares the higher tools version; fall back if the regular one is too new.
        let candidateToolsVersion = candidateVersion < .v4 ? .v3 : Self.parse(manifest: contentsOf(candidate) ?? "")
        if candidateToolsVersion > regularVersion || !hasRegular {
            return candidate
        }
        return regularVersion <= current ? WellKnownFile.manifest : candidate
    }

    /// `Package@swift-5.9.swift` → 5.9.0
    private static func versionSpecificManifestVersion(fileName: String) -> ToolsVersion? {
        guard fileName.hasPrefix(WellKnownFile.versionSpecificPrefix),
              fileName.hasSuffix(WellKnownFile.swiftExtension) else {
            return nil
        }
        let versionText = fileName
            .dropFirst(WellKnownFile.versionSpecificPrefix.count)
            .dropLast(WellKnownFile.swiftExtension.count)
        let parts = versionText.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, (1...3).contains(numbers.count) else {
            return nil
        }
        return ToolsVersion(numbers[0], numbers.count > 1 ? numbers[1] : 0, numbers.count > 2 ? numbers[2] : 0)
    }
}
