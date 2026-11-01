import Foundation
import Testing
@testable import SwxDevice

@Suite("Device background launch")
struct DeviceLaunchTests {
    @Test func installsThenLaunchesDetached() {
        let commands = DeviceRunner.deviceBackgroundCommands(app: URL(fileURLWithPath: "/tmp/App.app"), bundleIdentifier: "app.example", device: "0000-DEVICE", arguments: ["--demo", "working"])

        #expect(commands.count == 2)
        #expect(commands[0].suffix(5) == ["install", "app", "--device", "0000-DEVICE", "/tmp/App.app"])
        #expect(commands[1].contains("launch"))
        #expect(!commands[1].contains("--console"))
        #expect(commands[1].suffix(3) == ["app.example", "--demo", "working"])
    }
}
