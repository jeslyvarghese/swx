@testable import SwxApple
@testable import SwxDevice
import Testing

struct DestinationTests {
    @Test func formatsXcodebuildDestinations() {
        #expect(AppleDestination(platform: .iOS, environment: .simulator, deviceIdentifier: "ABC").xcodebuildDestination == "platform=iOS Simulator,id=ABC")
        #expect(AppleDestination(platform: .watchOS, environment: .device, deviceIdentifier: nil).xcodebuildDestination == "generic/platform=watchOS")
        #expect(AppleDestination(platform: .macOS, environment: .simulator, deviceIdentifier: nil).xcodebuildDestination == "generic/platform=macOS")
    }

    @Test func namesProductDirectories() {
        #expect(AppleDestination(platform: .iOS, environment: .simulator, deviceIdentifier: nil).productsDirectoryName(configuration: "Debug") == "Debug-iphonesimulator")
        #expect(AppleDestination(platform: .visionOS, environment: .device, deviceIdentifier: nil).productsDirectoryName(configuration: "Release") == "Release-xros")
        #expect(AppleDestination(platform: .macOS, environment: .device, deviceIdentifier: nil).productsDirectoryName(configuration: "Debug") == "Debug")
    }

    @Test func parsesPlatformArguments() {
        #expect(ApplePlatform(argument: "iOS") == .iOS)
        #expect(ApplePlatform(argument: "xros") == .visionOS)
        #expect(ApplePlatform(argument: "android") == nil)
    }

    @Test func parsesSimulatorRuntimes() {
        #expect(DeviceRunner.parseRuntime("com.apple.CoreSimulator.SimRuntime.iOS-27-0")! == (.iOS, "27.0"))
        #expect(DeviceRunner.parseRuntime("com.apple.CoreSimulator.SimRuntime.xrOS-3-1")! == (.visionOS, "3.1"))
        #expect(DeviceRunner.parseRuntime("com.example.Other") == nil)
    }

    @Test func comparesVersionsNumerically() {
        #expect(DeviceRunner.compareVersions("9.0", "27.0"))
        #expect(!DeviceRunner.compareVersions("27.0", "26.5"))
    }
}
