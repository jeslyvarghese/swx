import Foundation
@testable import SwxHotReload
import Testing

struct PatchJobTests {
    private static let directory = URL(fileURLWithPath: "/work/App")
    private static let object = URL(fileURLWithPath: "/work/patch.o")

    @Test func keepsTheChangedFileAsTheOnlyPrimaryAndDropsSideOutputs() throws {
        let job = [
            "/usr/bin/swift-frontend", "-frontend", "-c",
            "-primary-file", "/work/App/A.swift", "-primary-file", "/work/App/B.swift", "/work/App/C.swift",
            "-o", "/build/A.o", "-o", "/build/B.o",
            "-serialize-diagnostics-path", "/build/A.dia", "-index-store-path", "/build/index",
            "-module-name", "App",
        ]
        let patch = try #require(PatchCompiler.patchJob(from: job, primary: URL(fileURLWithPath: "/work/App/B.swift"), object: Self.object, workingDirectory: Self.directory))
        #expect(patch == [
            "/usr/bin/swift-frontend", "-frontend", "-c",
            "/work/App/A.swift", "-primary-file", "/work/App/B.swift", "/work/App/C.swift",
            "-module-name", "App", "-o", "/work/patch.o",
        ])
    }

    @Test func otherFilesJobsAreSkipped() {
        let job = ["/usr/bin/swift-frontend", "-frontend", "-c", "-primary-file", "/work/App/A.swift", "-o", "/build/A.o"]
        #expect(PatchCompiler.patchJob(from: job, primary: URL(fileURLWithPath: "/work/App/B.swift"), object: Self.object, workingDirectory: Self.directory) == nil)
    }

    @Test func relativePrimaryFilesResolveAgainstTheWorkingDirectory() {
        let job = ["swift-frontend", "-frontend", "-c", "-primary-file", "Sources/B.swift"]
        #expect(PatchCompiler.patchJob(from: job, primary: URL(fileURLWithPath: "/work/App/Sources/B.swift"), object: Self.object, workingDirectory: Self.directory) != nil)
    }

    @Test func stableHashesDontChangeBetweenRuns() {
        #expect(StableHash.hex(["agent", "arm64-apple-ios17.0-simulator"]) == StableHash.hex(["agent", "arm64-apple-ios17.0-simulator"]))
        #expect(StableHash.hex(["ab", "c"]) != StableHash.hex(["a", "bc"]))
    }
}
