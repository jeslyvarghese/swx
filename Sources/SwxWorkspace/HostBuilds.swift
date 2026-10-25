import Foundation
import SwxBuild
import SwxManifest
import SwxStore
import SwxSystem

/// Host (`swift build|test|run`) build settings swx adds on top of the user's arguments.
public enum HostBuilds {
    /// `SWX_BUILD_CACHE`: `0` turns caching off; `1` also opts into SwiftPM's native build system,
    /// which compiler-level caching needs.
    private enum Setting: String {
        case disabled = "0"
        case forced = "1"
    }

    private static let settingVariable = "SWX_BUILD_CACHE"

    /// Flags enabling the shared compilation cache in the store, when the toolchain supports it:
    /// SwiftPM's own `--enable-build-caching` where it exists, else the compiler's CAS under the
    /// native build system (chosen by the user, or opted into with `SWX_BUILD_CACHE=1`).
    public static func cacheArguments(existing: [String], cacheDirectory: URL?, packageDirectory: URL) async -> [String] {
        let setting = ProcessInfo.processInfo.environment[Self.settingVariable].flatMap(Setting.init(rawValue:))
        guard setting != .disabled else { return [] }
        let store = cacheDirectory.map(Store.init(root:)) ?? Store.default()

        if await Self.toolchainSupports(.swiftPMBuildCaching, store: store) {
            let driver = SwiftPMBuildDriver(compilationCache: store.compilationCachePath)
            return (try? await driver.cacheArguments(existing: existing)) ?? []
        }

        // The user's own caching flags win.
        guard !existing.contains(where: { $0.contains(Self.casFlagMarker) }),
              await Self.toolchainSupports(.compilerCaching, store: store) else {
            return []
        }
        let cache = SwiftPMBuildDriver.compilerCacheArguments(cache: store.compilationCachePath, packageDirectory: packageDirectory)
        if SwiftPMBuildDriver.usesNativeBuildSystem(existing) {
            return cache
        }
        return setting == .forced ? SwiftPMBuildDriver.nativeBuildSystemArguments + cache : []
    }

    private static let casFlagMarker = "cas-path"

    private enum Answer: String {
        case supported = "1"
        case unsupported = "0"
    }

    /// Caching features probed per toolchain.
    private enum Feature: String {
        case swiftPMBuildCaching = "build-caching-"
        case compilerCaching = "compiler-caching-"
    }

    /// Each probe runs once per toolchain; the answer is remembered in the store.
    private static func toolchainSupports(_ feature: Feature, store: Store) async -> Bool {
        guard let toolchain = try? await Toolchain.detect(store: store) else { return false }
        let record = store.toolchainCachePath(fingerprint: feature.rawValue + toolchain.key)
        if let cached = FileSystem.readIfPresent(record).map({ String(decoding: $0, as: UTF8.self) }).flatMap(Answer.init(rawValue:)) {
            return cached == .supported
        }
        let supported: Bool
        switch feature {
        case .swiftPMBuildCaching:
            supported = await SwiftPMBuildDriver.supportsBuildCaching()
        case .compilerCaching:
            supported = await SwiftPMBuildDriver.supportsCompilerCaching()
        }
        try? FileSystem.writeAtomically(Data((supported ? Answer.supported : Answer.unsupported).rawValue.utf8), to: record)
        return supported
    }
}
