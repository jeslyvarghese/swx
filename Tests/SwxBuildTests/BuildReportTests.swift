import Foundation
import SwxBuild
import Testing

struct BuildDiagnosticsTests {
    @Test func readsColouredSwiftDiagnosticsOnce() {
        let log = """
        error: SwiftCompile normal arm64 /work/Sources/Lib/A.swift failed with a nonzero exit code. Command line:     cd /work
        /work/Sources/Lib/A.swift:4:38: \u{1B}[1;31merror: \u{1B}[1;39muse of 'add' refers to instance method\u{1B}[0;0m
          |                                      |- \u{1B}[1;31merror: \u{1B}[1;39muse of 'add' refers to instance method\u{1B}[0;0m
        Lib.add:1:13: note: 'add' declared here
        /work/Sources/Lib/A.swift:4:38: error: use of 'add' refers to instance method
        /work/My: Dir/B.swift:10:2: warning: variable 'x' was never used
        error: Build failed
        """
        let diagnostics = BuildLog.diagnostics(in: log)
        #expect(diagnostics == [
            BuildDiagnostic(severity: .error, file: "/work/Sources/Lib/A.swift", line: 4, column: 38, message: "use of 'add' refers to instance method"),
            BuildDiagnostic(severity: .warning, file: "/work/My: Dir/B.swift", line: 10, column: 2, message: "variable 'x' was never used"),
        ])
    }

    @Test func keepsUnlocatedErrorsWhenNothingElseExplains() {
        let log = """
        Undefined symbols for architecture arm64:
          "_missing", referenced from:
              _main in main.o
        ld: symbol(s) not found for architecture arm64
        clang: error: linker command failed with exit code 1
        <unknown>:0: error: unable to load standard library
        error: Build failed
        """
        #expect(BuildLog.diagnostics(in: log).map(\.message) == [
            "Undefined symbols for architecture arm64: \"_missing\", referenced from:",
            "clang: linker command failed with exit code 1",
            "unable to load standard library",
        ])
    }

    @Test func xcTestFailuresAreNotCompilerDiagnostics() {
        let log = "/work/Tests/T.swift:5: error: -[T.X testFail] : XCTAssertEqual failed"
        #expect(BuildLog.diagnostics(in: log).isEmpty)
    }
}

struct TestLogTests {
    private static let log = """
    Test Case '-[LibTests.XTests testFail]' started.
    /work/Tests/LibTests/XCTests.swift:5: error: -[LibTests.XTests testFail] : XCTAssertEqual failed: ("2") is not equal to ("3") - math
    Test Case '-[LibTests.XTests testFail]' failed (0.029 seconds).
    Test Case '-[LibTests.XTests testPass]' passed (0.000 seconds).
    /work/Tests/LibTests/XCTests.swift:6: -[LibTests.XTests testSkip] : Test skipped - later
    Test Case '-[LibTests.XTests testSkip]' skipped (0.001 seconds).
    Test Suite 'XTests' failed at 2026-10-29 10:09:00.479.
    ◇ Test run started.
    ↳ Testing Library Version: 2084
    ◇ Suite Adding started.
    ➜ Test off() skipped: "not now"
    ✔ Test passes() passed after 0.001 seconds.
    ✘ Test fails() recorded an issue at STests.swift:5:26: Expectation failed: plus(2, 2) == 5
    ↳ plus(2, 2) == 5 → false
    ↳   plus(2, 2) → 4
    ✘ Test fails() failed after 0.001 seconds with 1 issue.
    ✘ Suite Adding failed after 0.001 seconds with 1 issue.
    ✘ Test run with 3 tests in 1 suite failed after 0.001 seconds with 1 issue.
    """

    @Test func countsXCTestAndSwiftTesting() {
        let report = TestLog.report(in: Self.log)
        #expect(report.passed == 2)
        #expect(report.skipped == 2)
        #expect(report.failed == 2)
        #expect(report.failures.map(\.test) == ["LibTests.XTests/testFail", "fails()"])
    }

    @Test func keepsWhereAndWhyEachTestFailed() {
        let failures = TestLog.report(in: Self.log).failures
        #expect(failures[0].issues == [TestIssue(file: "/work/Tests/LibTests/XCTests.swift", line: 5, message: "XCTAssertEqual failed: (\"2\") is not equal to (\"3\") - math")])
        #expect(failures[1].issues == [TestIssue(file: "STests.swift", line: 5, message: "Expectation failed: plus(2, 2) == 5\nplus(2, 2) == 5 → false\nplus(2, 2) → 4")])
    }

    @Test func readsXcodeResultBundles() throws {
        let json = """
        {"testNodes":[{"nodeType":"Test Plan","result":"Failed","children":[{"nodeType":"Unit test bundle","children":[
          {"nodeType":"Test Suite","children":[
            {"nodeType":"Test Case","name":"testFail()","nodeIdentifier":"XTests/testFail()","result":"Failed","children":[
              {"nodeType":"Failure Message","name":"XCTAssertEqual failed","sourceLocation":{"filePath":"/w/X.swift","lineNumber":5}}]},
            {"nodeType":"Test Case","name":"testPass()","nodeIdentifier":"XTests/testPass()","result":"Passed"},
            {"nodeType":"Test Case","name":"off()","nodeIdentifier":"Adding/off()","result":"Skipped"},
            {"nodeType":"Test Case","name":"each(_:)","nodeIdentifier":"Adding/each(_:)","result":"Failed","children":[
              {"nodeType":"Arguments","name":"2","children":[{"nodeType":"Failure Message","name":"Expectation failed"}]}]}
          ]}]}]}]}
        """
        let report = try #require(XCResultTests.report(from: Data(json.utf8)))
        #expect((report.passed, report.failed, report.skipped) == (1, 2, 1))
        #expect(report.failures.map(\.test) == ["XTests/testFail()", "Adding/each(_:)"])
        #expect(report.failures[0].issues == [TestIssue(file: "/w/X.swift", line: 5, message: "XCTAssertEqual failed")])
        #expect(report.failures[1].issues == [TestIssue(file: nil, line: nil, message: "Expectation failed")])
    }
}
