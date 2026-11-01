import SwxApple
@testable import SwxDevice
import Testing

/// Picking a simulator: an explicit name wins; otherwise the app's device families decide
/// before "whatever is booted".
struct SimulatorChoiceTests {
    private func simulator(_ name: String, _ family: DeviceFamily, version: String = "27.0", booted: Bool = false) -> RunTarget {
        RunTarget(identifier: name, name: name, platform: .iOS, environment: .simulator, osVersion: version, isBooted: booted, family: family)
    }

    @Test func familiesComeFromDeviceTypes() {
        #expect(DeviceFamily(deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro") == .phone)
        #expect(DeviceFamily(deviceType: "com.apple.CoreSimulator.SimDeviceType.iPad-A16") == .pad)
        #expect(DeviceFamily(deviceType: "iPhone") == .phone)
        #expect(DeviceFamily(deviceType: "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11") == .other)
        #expect(DeviceFamily(deviceType: nil) == .other)
    }

    @Test func aPhoneOnlyAppSkipsABootedPad() throws {
        let candidates = [self.simulator("iPad (A16)", .pad, booted: true), self.simulator("iPhone 17 Pro", .phone)]
        let chosen = try DeviceRunner.chooseSimulator(from: candidates, platform: .iOS, matching: nil, preferring: [.phone])
        #expect(chosen.name == "iPhone 17 Pro")
    }

    @Test func aBootedMatchingDeviceComesFirst() throws {
        let candidates = [self.simulator("iPhone 17", .phone), self.simulator("iPhone 17 Pro", .phone, booted: true)]
        let chosen = try DeviceRunner.chooseSimulator(from: candidates, platform: .iOS, matching: nil, preferring: [.phone])
        #expect(chosen.name == "iPhone 17 Pro")
    }

    @Test func theNewestRuntimeWinsAmongMatchingDevices() throws {
        let candidates = [self.simulator("iPhone 16", .phone, version: "26.5"), self.simulator("iPhone 17", .phone, version: "27.0"), self.simulator("iPad Pro", .pad, version: "27.0")]
        let chosen = try DeviceRunner.chooseSimulator(from: candidates, platform: .iOS, matching: nil, preferring: [.phone])
        #expect(chosen.name == "iPhone 17")
    }

    @Test func noFamiliesOrNoMatchKeepsTheOldBehaviour() throws {
        let candidates = [self.simulator("iPad (A16)", .pad, booted: true), self.simulator("iPhone 17 Pro", .phone)]
        #expect(try DeviceRunner.chooseSimulator(from: candidates, platform: .iOS, matching: nil, preferring: []).name == "iPad (A16)")

        let pads = [self.simulator("iPad (A16)", .pad, booted: true)]
        #expect(try DeviceRunner.chooseSimulator(from: pads, platform: .iOS, matching: nil, preferring: [.phone]).name == "iPad (A16)")
    }

    @Test func anExplicitNameWins() throws {
        let candidates = [self.simulator("iPad (A16)", .pad), self.simulator("iPhone 17 Pro", .phone, booted: true)]
        let chosen = try DeviceRunner.chooseSimulator(from: candidates, platform: .iOS, matching: "iPad (A16)", preferring: [.phone])
        #expect(chosen.name == "iPad (A16)")
    }
}
