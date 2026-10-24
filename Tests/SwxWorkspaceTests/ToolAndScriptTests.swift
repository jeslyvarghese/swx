import SwxCore
import SwxSource
@testable import SwxWorkspace
import Testing

struct ToolSpecTests {
    @Test func expandsAliasesAndShorthands() {
        #expect(ToolRunner.parse("swiftformat@0.54.0") == .init(url: "https://github.com/nicklockwood/SwiftFormat.git", version: "0.54.0", hint: "swiftformat"))
        #expect(ToolRunner.parse("realm/SwiftLint").url == "https://github.com/realm/SwiftLint.git")
        #expect(ToolRunner.parse("https://example.com/tool.git@1.2").version == "1.2")
        #expect(ToolRunner.parse("git@github.com:owner/tool.git").version == nil)
        #expect(ToolRunner.parse("git@github.com:owner/tool.git@2.0.0").version == "2.0.0")
    }

    @Test func choosesVersions() {
        let tagged = ["1.0.0", "1.2.0", "1.2.5", "2.0.0-beta.1"].map { TaggedVersion(version: Version($0)!, revision: $0) }
        #expect(ToolRunner.choose(nil, from: tagged)?.version == Version(1, 2, 5))
        #expect(ToolRunner.choose("1.2", from: tagged)?.version == Version(1, 2, 5))
        #expect(ToolRunner.choose("1.0.0", from: tagged)?.version == Version(1, 0, 0))
        #expect(ToolRunner.choose("2.0.0-beta.1", from: tagged)?.version == Version("2.0.0-beta.1"))
        #expect(ToolRunner.choose("3", from: tagged) == nil)
    }
}

struct ScriptHeaderTests {
    private let script = """
    #!/usr/bin/env -S swx run
    // A friendly script.
    // swx-dependencies:
    // .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    //   .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0")

    import ArgumentParser
    @testable import DequeModule
    import struct Foundation.URL
    // .package(url: "https://example.com/not-a-dependency.git", from: "1.0.0")
    """

    @Test func readsDependencyBlock() {
        #expect(ScriptRunner.dependencyDeclarations(in: self.script) == [
            ".package(url: \"https://github.com/apple/swift-argument-parser\", from: \"1.3.0\")",
            ".package(url: \"https://github.com/apple/swift-collections.git\", from: \"1.1.0\")",
        ])
    }

    @Test func readsImports() {
        #expect(ScriptRunner.imports(in: self.script) == ["ArgumentParser", "DequeModule", "Foundation"])
    }
}
