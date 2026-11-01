import Foundation
@testable import SwxBuild
import Testing

/// A scheme that builds an iOS app and its watch app compiles shared libraries for both
/// simulators, with the same architecture: they're different modules to hot reload.
struct SwiftModuleCommandTests {
    private func command(_ module: String, target: String, sdk: String) -> SwiftModuleCommand {
        SwiftModuleCommand(module: module, architecture: "arm64", arguments: ["swiftc", "-target", target, "-sdk", sdk], workingDirectory: "/w")
    }

    private let iOS = "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator27.0.sdk"
    private let watchOS = "/Applications/Xcode.app/Contents/Developer/Platforms/WatchSimulator.platform/Developer/SDKs/WatchSimulator27.0.sdk"

    @Test func modulesKnowTheirSDK() {
        let core = self.command("Core", target: "arm64-apple-ios26.0-simulator", sdk: self.iOS)
        #expect(core.usesSDK(named: "iphonesimulator"))
        #expect(!core.usesSDK(named: "watchsimulator"))
    }

    @Test func iOSAndWatchBuildsOfOneModuleAreKeptApart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swx-modules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SwiftModuleCommandStore(derivedData: directory)
        let merged = store.merge([
            self.command("Core", target: "arm64-apple-ios26.0-simulator", sdk: self.iOS),
            self.command("Core", target: "arm64-apple-watchos26.0-simulator", sdk: self.watchOS),
        ])
        #expect(merged.count == 2)
        #expect(merged.filter { $0.usesSDK(named: "iphonesimulator") }.map(\.module) == ["Core"])

        // A later build of one of them replaces only that one.
        let again = store.merge([self.command("Core", target: "arm64-apple-ios26.0-simulator", sdk: self.iOS)])
        #expect(again.count == 2)
    }
}
