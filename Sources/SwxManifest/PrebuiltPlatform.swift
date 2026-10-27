import Foundation
import SwxCore
import SwxStore
import SwxSystem

/// The host as SwiftPM names it for prebuilt libraries (`PrebuiltsPlatform`).
public enum PrebuiltPlatform: String, Sendable {
    case macos_universal
    case ubuntu_noble_aarch64
    case ubuntu_noble_x86_64
    case ubuntu_jammy_aarch64
    case ubuntu_jammy_x86_64
    case ubuntu_focal_aarch64
    case ubuntu_focal_x86_64
    case fedora_39_aarch64
    case fedora_39_x86_64
    case amazonlinux2_aarch64
    case amazonlinux2_x86_64
    case rhel_ubi9_aarch64
    case rhel_ubi9_x86_64
    case debian_12_aarch64
    case debian_12_x86_64

    enum Arch: String {
        case aarch64
        case x86_64
    }

    private static let osRelease = "/etc/os-release"
    private static let zipExtension = ".zip"
    private static let tarExtension = ".tar.gz"

    /// Archives are zips, except on Linux.
    public var archiveExtension: String {
        self == .macos_universal ? Self.zipExtension : Self.tarExtension
    }

    /// This machine, or `nil` where SwiftPM has no prebuilts.
    public static var host: PrebuiltPlatform? {
        #if arch(arm64)
        let arch = Arch.aarch64
        #elseif arch(x86_64)
        let arch = Arch.x86_64
        #else
        return nil
        #endif

        #if os(macOS)
        return .macos_universal
        #elseif os(Linux)
        guard let text = try? String(contentsOfFile: Self.osRelease, encoding: .utf8) else { return nil }
        return Self.linux(osRelease: text, arch: arch)
        #else
        return nil
        #endif
    }

    /// SwiftPM's mapping from `/etc/os-release` (distribution and release) to a platform.
    static func linux(osRelease text: String, arch: Arch) -> PrebuiltPlatform? {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            fields[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }

        let release: String?
        switch fields["ID"] {
        case "ubuntu":
            release = ["noble", "jammy", "focal"].contains(fields["VERSION_CODENAME"] ?? "") ? "ubuntu_\(fields["VERSION_CODENAME"] ?? "")" : nil
        case "fedora":
            release = ["39", "41"].contains(fields["VERSION_ID"] ?? "") ? "fedora_39" : nil
        case "amzn":
            release = fields["VERSION_ID"] == "2" ? "amazonlinux2" : nil
        case "rhel":
            release = fields["VERSION_ID"]?.split(separator: ".").first == "9" ? "rhel_ubi9" : nil
        case "debian":
            release = fields["VERSION_ID"] == "12" ? "debian_12" : nil
        default:
            release = nil
        }
        return release.flatMap { PrebuiltPlatform(rawValue: "\($0)_\(arch.rawValue)") }
    }
}

extension Toolchain {
    private enum Prebuilt {
        static let compilerTag = "swiftCompilerTag"
        static let compilerVersion = "compilerVersion"
        /// Xcode's compilers are tagged `swiftlang-…`; their prebuilts are per SDK.
        static let xcodeTagPrefix = "swiftlang-"
        static let sdkSettings = "SDKSettings.json"
        static let canonicalName = "CanonicalName"
        static let cacheSuffix = "\u{0}prebuilt-name"
    }

    /// The name SwiftPM gives this toolchain's prebuilts: the compiler's tag, then the SDK's
    /// canonical name for an Xcode toolchain (`swiftlang-6.4.0.34.1-macosx27.0`) or the platform
    /// otherwise (`swift-6.4.1-RELEASE-ubuntu_noble_aarch64`). Cached per toolchain.
    public static func prebuiltName(platform: PrebuiltPlatform, store: Store = .default()) async throws -> String? {
        let fingerprint = ExecutableLookup.fingerprint(of: "swift")
        let cacheURL = store.toolchainCachePath(fingerprint: ContentHash.sha256(fingerprint + Prebuilt.cacheSuffix))
        if let cached = FileSystem.readIfPresent(cacheURL).map({ String(decoding: $0, as: UTF8.self) }), !cached.isEmpty {
            return cached
        }

        let result = try await ProcessRunner.run(["swift", "-print-target-info"])
        guard let info = try? JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any],
              let tag = Self.compilerTag(info) else {
            return nil
        }

        let name: String
        if platform == .macos_universal, tag.hasPrefix(Prebuilt.xcodeTagPrefix) {
            guard let sdk = try await Self.macOSSDKCanonicalName() else { return nil }
            name = "\(tag)-\(sdk)"
        } else {
            name = "\(tag)-\(platform.rawValue)"
        }
        try? FileSystem.writeAtomically(Data(name.utf8), to: cacheURL)
        return name
    }

    /// `swiftCompilerTag`, else the `(swiftlang-…)` or `Swift X` part of `compilerVersion`.
    static func compilerTag(_ info: [String: Any]) -> String? {
        if let tag = info[Prebuilt.compilerTag] as? String {
            return tag
        }
        guard let version = info[Prebuilt.compilerVersion] as? String else { return nil }
        if let match = version.firstMatch(of: /\((swift(lang)?-[^ )]*)/) {
            return String(match.1)
        }
        if let match = version.firstMatch(of: /\(.*Swift (.*)[ )]/) {
            return "swift-\(match.1)"
        }
        return nil
    }

    /// The host SDK's `CanonicalName` (`macosx27.0`), as SwiftPM reads it from SDKSettings.json.
    private static func macOSSDKCanonicalName() async throws -> String? {
        let path = try await ProcessRunner.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = URL(fileURLWithPath: path).appendingPathComponent(Prebuilt.sdkSettings)
        guard let data = FileSystem.readIfPresent(settings),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object[Prebuilt.canonicalName] as? String
    }
}
