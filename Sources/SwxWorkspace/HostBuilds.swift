import Foundation
import SwxBuild
import SwxManifest
import SwxStore
import SwxSystem

/// Host (`swift build|test|run`) build settings swx adds on top of the user's arguments.
public enum HostBuilds {
    private static let optOutVariable = "SWX_BUILD_CACHE"
    private static let optOutValue = "0"

    /// Flags enabling the shared compilation cache in the store, when the toolchain supports it.
    public static func cacheArguments(existing: [String], cacheDirectory: URL?) async -> [String] {
        guard ProcessInfo.processInfo.environment[Self.optOutVariable] != Self.optOutValue else {
            return []
        }
        let store = cacheDirectory.map(Store.init(root:)) ?? Store.default()
        guard await Self.toolchainSupportsCaching(store: store) else {
            return []
        }
        let driver = SwiftPMBuildDriver(compilationCache: store.compilationCachePath)
        return (try? await driver.cacheArguments(existing: existing)) ?? []
    }

    private enum Answer: String {
        case supported = "1"
        case unsupported = "0"
    }

    private static let featurePrefix = "build-caching-"

    /// `swift build --help` once per toolchain, remembered in the store.
    private static func toolchainSupportsCaching(store: Store) async -> Bool {
        guard let toolchain = try? await Toolchain.detect(store: store) else { return false }
        let record = store.toolchainCachePath(fingerprint: Self.featurePrefix + toolchain.key)
        if let cached = FileSystem.readIfPresent(record).map({ String(decoding: $0, as: UTF8.self) }).flatMap(Answer.init(rawValue:)) {
            return cached == .supported
        }
        let supported = await SwiftPMBuildDriver.supportsBuildCaching()
        try? FileSystem.writeAtomically(Data((supported ? Answer.supported : Answer.unsupported).rawValue.utf8), to: record)
        return supported
    }
}
