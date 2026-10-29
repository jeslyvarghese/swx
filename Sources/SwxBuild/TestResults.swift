import Foundation

/// The outcome of a test run, counted per test: XCTest and Swift Testing together.
public struct TestReport: Sendable, Codable, Hashable {
    public var passed: Int
    public var failed: Int
    public var skipped: Int
    public var failures: [TestFailure]

    public init(passed: Int = 0, failed: Int = 0, skipped: Int = 0, failures: [TestFailure] = []) {
        self.passed = passed
        self.failed = failed
        self.skipped = skipped
        self.failures = failures
    }

    public var isEmpty: Bool {
        self.passed + self.failed + self.skipped == 0
    }
}

/// One failing test and why: every recorded issue, with where it was recorded.
public struct TestFailure: Sendable, Codable, Hashable {
    public let test: String
    public var issues: [TestIssue]

    public init(test: String, issues: [TestIssue]) {
        self.test = test
        self.issues = issues
    }
}

public struct TestIssue: Sendable, Codable, Hashable {
    /// As the test library names it: absolute for XCTest, the file name for Swift Testing.
    public let file: String?
    public let line: Int?
    public let message: String

    public init(file: String?, line: Int?, message: String) {
        self.file = file
        self.line = line
        self.message = message
    }
}

/// Reads test results out of `swift test` output.
public enum TestLog {
    private enum XCTest {
        /// `Test Case '-[Module.Class testName]' passed (0.001 seconds).`
        static let testCase = "Test Case '"
        static let nameEnd = "' "
        static let failureSeparator = " : "
        static let errorMarker = ": error: "
        static let objectiveCOpen = "-["
        static let objectiveCClose = "]"
    }

    private enum SwiftTesting {
        static let test = "Test "
        /// The run's own summary line: `Test run with 4 tests …`.
        static let runSummary = "Test run with "
        static let passed = " passed after "
        static let failed = " failed after "
        static let skipped = " skipped"
        static let issue = " recorded an issue at "
        static let issueWithoutLocation = " recorded an issue: "
        static let suite = "Suite "
        static let locationSeparator: Character = ":"
        static let messageSeparator = ": "
    }

    private enum Outcome: String {
        case passed
        case failed
        case skipped
    }

    public static func report(in log: String) -> TestReport {
        var outcomes: [String: Outcome] = [:]
        var order: [String] = []
        var issues: [String: [TestIssue]] = [:]
        var lastIssue: (test: String, index: Int)?

        func record(_ test: String, _ outcome: Outcome) {
            if outcomes[test] == nil {
                order.append(test)
            }
            outcomes[test] = outcome
        }

        for rawLine in log.split(whereSeparator: \.isNewline) {
            let line = BuildLog.removingEscapes(String(rawLine))

            // XCTest: `Test Case '…' passed|failed|skipped (…)`.
            if line.hasPrefix(XCTest.testCase), let (name, outcome) = Self.xcTestCase(line) {
                record(name, outcome)
                lastIssue = nil
                continue
            }

            // XCTest: `/path/File.swift:12: error: -[Module.Class test] : message`.
            if let (name, issue) = Self.xcTestFailure(line) {
                issues[name, default: []].append(issue)
                lastIssue = nil
                continue
            }

            // Swift Testing lines start with a symbol; the details of an issue (`↳ x → 4`)
            // follow it, as symbol lines that aren't events.
            let symbolless = Self.droppingSymbol(line)
            let isEvent = symbolless.hasPrefix(SwiftTesting.test) || symbolless.hasPrefix(SwiftTesting.suite)
            if let last = lastIssue, symbolless != line, !isEvent {
                let existing = issues[last.test]![last.index]
                issues[last.test]![last.index] = TestIssue(file: existing.file, line: existing.line, message: existing.message + "\n" + symbolless)
                continue
            }
            lastIssue = nil
            guard symbolless.hasPrefix(SwiftTesting.test), !symbolless.hasPrefix(SwiftTesting.runSummary) else { continue }
            let rest = String(symbolless.dropFirst(SwiftTesting.test.count))

            if let (name, issue) = Self.swiftTestingIssue(rest) {
                issues[name, default: []].append(issue)
                lastIssue = (name, issues[name]!.count - 1)
                continue
            }
            for (marker, outcome) in [(SwiftTesting.passed, Outcome.passed), (SwiftTesting.failed, .failed), (SwiftTesting.skipped, .skipped)] {
                guard let range = rest.range(of: marker) else { continue }
                record(String(rest[..<range.lowerBound]), outcome)
                break
            }
        }

        // Count each test once, by its last outcome; failures keep the run's order.
        var report = TestReport()
        for test in order {
            switch outcomes[test]! {
            case .passed:
                report.passed += 1
            case .skipped:
                report.skipped += 1
            case .failed:
                report.failed += 1
                report.failures.append(TestFailure(test: test, issues: issues[test] ?? []))
            }
        }
        return report
    }

    private static func xcTestCase(_ line: String) -> (String, Outcome)? {
        let rest = line.dropFirst(XCTest.testCase.count)
        guard let end = rest.range(of: XCTest.nameEnd) else { return nil }
        let word = rest[end.upperBound...].prefix { $0.isLetter }
        guard let outcome = Outcome(rawValue: String(word)) else { return nil }
        return (Self.testName(String(rest[..<end.lowerBound])), outcome)
    }

    private static func xcTestFailure(_ line: String) -> (String, TestIssue)? {
        guard let marker = line.range(of: XCTest.errorMarker),
              let separator = line[marker.upperBound...].range(of: XCTest.failureSeparator) else {
            return nil
        }

        // `path:line` before the marker; a column would make it a compiler diagnostic.
        let location = line[..<marker.lowerBound]
        guard let colon = location.lastIndex(of: ":"), let number = Int(location[location.index(after: colon)...]) else { return nil }
        let file = String(location[..<colon])
        let beforeLine = file.split(separator: ":").last ?? ""
        guard file.contains(":") == false || !beforeLine.allSatisfy(\.isNumber) else { return nil }

        let name = String(line[marker.upperBound..<separator.lowerBound])
        let message = String(line[separator.upperBound...])
        return (Self.testName(name), TestIssue(file: file, line: number, message: message))
    }

    /// `fails() recorded an issue at File.swift:5:26: Expectation failed: …`
    private static func swiftTestingIssue(_ rest: String) -> (String, TestIssue)? {
        if let range = rest.range(of: SwiftTesting.issue) {
            let name = String(rest[..<range.lowerBound])
            let after = rest[range.upperBound...]
            guard let message = after.range(of: SwiftTesting.messageSeparator) else { return nil }

            // `File.swift:5:26`: the file, then the line.
            let location = after[..<message.lowerBound].split(separator: SwiftTesting.locationSeparator)
            let line = location.count >= 2 ? Int(location[1]) : nil
            return (name, TestIssue(file: location.first.map(String.init), line: line, message: String(after[message.upperBound...])))
        }
        guard let range = rest.range(of: SwiftTesting.issueWithoutLocation) else { return nil }
        return (String(rest[..<range.lowerBound]), TestIssue(file: nil, line: nil, message: String(rest[range.upperBound...])))
    }

    /// `-[Module.Class testName]` → `Module.Class/testName`, as `--filter` takes it.
    private static func testName(_ name: String) -> String {
        guard name.hasPrefix(XCTest.objectiveCOpen), name.hasSuffix(XCTest.objectiveCClose) else { return name }
        let inner = name.dropFirst(XCTest.objectiveCOpen.count).dropLast(XCTest.objectiveCClose.count)
        return inner.replacingOccurrences(of: " ", with: "/")
    }

    /// Swift Testing prefixes events with a symbol (`✔`, `✘`, or an SF Symbol in a terminal).
    private static func droppingSymbol(_ line: String) -> String {
        guard let first = line.unicodeScalars.first, !first.isASCII else { return line }
        return String(line.drop { !$0.isASCII || $0 == " " })
    }
}

/// Reads test results out of an xcodebuild result bundle (`xcresulttool get test-results tests`),
/// which names every test by its identifier and locates every failure.
public enum XCResultTests {
    private enum Key {
        static let testNodes = "testNodes"
        static let children = "children"
        static let nodeType = "nodeType"
        static let name = "name"
        static let identifier = "nodeIdentifier"
        static let result = "result"
        static let sourceLocation = "sourceLocation"
        static let filePath = "filePath"
        static let lineNumber = "lineNumber"
    }

    private enum NodeType {
        static let testCase = "Test Case"
        static let failureMessage = "Failure Message"
    }

    private enum Result {
        static let passed = "Passed"
        static let failed = "Failed"
        static let skipped = "Skipped"
        static let expectedFailure = "Expected Failure"
    }

    /// `nil` when `json` isn't xcresulttool's test results.
    public static func report(from json: Data) -> TestReport? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let nodes = root[Key.testNodes] as? [[String: Any]] else {
            return nil
        }
        var report = TestReport()
        Self.collect(nodes, into: &report)
        return report
    }

    private static func collect(_ nodes: [[String: Any]], into report: inout TestReport) {
        for node in nodes {
            guard node[Key.nodeType] as? String == NodeType.testCase else {
                Self.collect(node[Key.children] as? [[String: Any]] ?? [], into: &report)
                continue
            }

            // A test case: counted by its result; a failing one lists its failure messages.
            switch node[Key.result] as? String {
            case Result.passed, Result.expectedFailure:
                report.passed += 1
            case Result.skipped:
                report.skipped += 1
            case Result.failed:
                report.failed += 1
                let name = node[Key.identifier] as? String ?? node[Key.name] as? String ?? ""
                report.failures.append(TestFailure(test: name, issues: Self.issues(in: node)))
            default:
                continue
            }
        }
    }

    /// Failure messages anywhere under a test case (parameterized tests nest them per argument).
    private static func issues(in node: [String: Any]) -> [TestIssue] {
        var issues: [TestIssue] = []
        for child in node[Key.children] as? [[String: Any]] ?? [] {
            guard child[Key.nodeType] as? String == NodeType.failureMessage else {
                issues += Self.issues(in: child)
                continue
            }
            let location = child[Key.sourceLocation] as? [String: Any]
            issues.append(TestIssue(
                file: location?[Key.filePath] as? String,
                line: location?[Key.lineNumber] as? Int,
                message: child[Key.name] as? String ?? ""
            ))
        }
        return issues
    }
}
