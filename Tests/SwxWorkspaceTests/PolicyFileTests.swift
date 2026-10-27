import Foundation
import SwxWorkspace
import Testing

struct PolicyFileTests {
    @Test func decodesSections() throws {
        let policy = try Policy.decode(Data(#"{"audit": {"ignore": ["GHSA-x"], "failOn": "high"}, "outdated": {"ignore": ["Swift-NIO"], "failOn": "wanted"}}"#.utf8))
        #expect(policy == Policy(audit: AuditPolicy(ignore: ["GHSA-x"], failOn: .high), outdated: OutdatedPolicy(ignore: ["swift-nio"], failOn: .wanted)))
    }

    /// Absent sections and fields keep the defaults: every advisory fails, outdated only reports.
    @Test func defaultsWhatIsMissing() throws {
        #expect(try Policy.decode(Data("{}".utf8)) == Policy())
        #expect(try Policy.decode(Data(#"{"audit": {"ignore": ["GHSA-x"]}}"#.utf8)).audit.failOn == .low)
    }

    @Test func namesTheFieldAtFault() {
        #expect {
            try Policy.decode(Data(#"{"audit": {"failOn": "severe"}}"#.utf8))
        } throws: { error in
            "\(error)".hasPrefix(".swx/policy.json: audit.failOn: ")
        }
    }
}
