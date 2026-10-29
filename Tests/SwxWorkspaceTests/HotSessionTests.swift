import Foundation
import SwxWorkspace
import Testing

struct HotSessionTests {
    @Test func phaseFollowsTheLastEvent() {
        #expect(HotSession.phase(after: nil, running: true) == .starting)
        #expect(HotSession.phase(after: .relaunching, running: true) == .building)
        #expect(HotSession.phase(after: .notReloaded, running: true) == .watching)
        #expect(HotSession.phase(after: .buildFailed, running: true) == .waitingForFix)
        #expect(HotSession.phase(after: .stopped, running: false) == .stopped)
        #expect(HotSession.phase(after: .watching, running: false) == .ended)
    }

    @Test func noSessionReadsAsNotRunning() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swx-hot-\(UUID().uuidString)")
        let status = HotSession(packageDirectory: directory).status()
        #expect(!status.running)
        #expect(status.phase == .notRunning)
    }
}
