import Foundation
import SwxSystem
import Testing

struct ProcessRunnerTests {
    /// Large outputs arrive complete and in order, with stderr written at the same time, with many
    /// processes finishing at once. A guard, not a reproduction: the old reader (a readability handler
    /// still running while the rest of the pipe was read) only spliced output under heavy load.
    @Test func keepsLargeOutputInOrder() async throws {
        let lines = 60_000
        let stderrEvery = 500
        let script = "BEGIN { for (i = 0; i < \(lines); i++) { print i; if (i % \(stderrEvery) == 0) print i > \"/dev/stderr\" } }"
        let expected = Data((0..<lines).map { "\($0)\n" }.joined().utf8)
        let concurrent = 16
        let rounds = 12

        for _ in 0..<rounds {
            let outputs = try await withThrowingTaskGroup(of: Data.self) { group in
                for _ in 0..<concurrent {
                    group.addTask { try await ProcessRunner.run(["awk", script]).standardOutput }
                }
                return try await group.reduce(into: [Data]()) { $0.append($1) }
            }
            #expect(outputs.allSatisfy { $0 == expected })
        }
    }

    /// Input is delivered whole, and output of a child that reads it comes back intact.
    @Test func roundTripsStandardInput() async throws {
        let input = Data((0..<50_000).map { "line \($0)\n" }.joined().utf8)
        let result = try await ProcessRunner.run(["cat"], input: input)
        #expect(result.standardOutput == input)
    }
}
