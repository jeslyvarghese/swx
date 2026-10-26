import Testing
@testable import SwxWorkspace

struct SelectiveTestingTests {
    /// Only the targets to run get through `--filter`, by module name; no filter when all run.
    @Test func filtersTestModules() {
        let partial = SelectiveTestPlan(run: ["CoreTests", "Web-Tests"], skipped: ["AppTests"], keys: [:])
        #expect(partial.filter == "^(CoreTests|Web_Tests)\\.")

        let everything = SelectiveTestPlan(run: ["CoreTests"], skipped: [], keys: [:])
        #expect(everything.filter == nil)
    }
}
