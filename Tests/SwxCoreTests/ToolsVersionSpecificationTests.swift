import SwxCore
import Testing

struct ToolsVersionSpecificationTests {
    /// SwiftPM: the first line, else (only for 6.0 and later) a later one; none at all is 3.1.
    @Test func readsTheSpecificationWhereSwiftPMDoes() throws {
        #expect(try ToolsVersion.specification(of: "// swift-tools-version:5.9\nimport PackageDescription\n") == ToolsVersion(5, 9, 0))
        #expect(try ToolsVersion.specification(of: "//\n// Package.swift\n// swift-tools-version: 6.1\n") == ToolsVersion(6, 1, 0))
        #expect(try ToolsVersion.specification(of: "import PackageDescription\n") == .v3)
        #expect(throws: ToolsVersion.LaterLineSpecification.self) {
            try ToolsVersion.specification(of: "//\n// Package.swift\n// swift-tools-version:5.0\nimport PackageDescription\n")
        }
    }
}
