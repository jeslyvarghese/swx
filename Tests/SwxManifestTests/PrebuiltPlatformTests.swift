@testable import SwxManifest
import Testing

struct PrebuiltPlatformTests {
    /// SwiftPM's os-release mapping: distribution and release, then the CPU.
    @Test func mapsLinuxReleases() {
        let noble = "NAME=\"Ubuntu\"\nID=ubuntu\nVERSION_ID=\"24.04\"\nVERSION_CODENAME=noble\n"
        #expect(PrebuiltPlatform.linux(osRelease: noble, arch: .aarch64) == .ubuntu_noble_aarch64)
        #expect(PrebuiltPlatform.linux(osRelease: noble, arch: .x86_64) == .ubuntu_noble_x86_64)
        #expect(PrebuiltPlatform.linux(osRelease: "ID=fedora\nVERSION_ID=41\n", arch: .x86_64) == .fedora_39_x86_64)
        #expect(PrebuiltPlatform.linux(osRelease: "ID=\"rhel\"\nVERSION_ID=\"9.4\"\n", arch: .aarch64) == .rhel_ubi9_aarch64)
        #expect(PrebuiltPlatform.linux(osRelease: "ID=alpine\nVERSION_ID=3.20.0\n", arch: .aarch64) == nil)
        #expect(PrebuiltPlatform.ubuntu_noble_x86_64.archiveExtension == ".tar.gz")
        #expect(PrebuiltPlatform.macos_universal.archiveExtension == ".zip")
    }

    /// The compiler's tag, else the part of its version string SwiftPM extracts.
    @Test func readsCompilerTags() {
        #expect(Toolchain.compilerTag(["swiftCompilerTag": "swiftlang-6.4.0.34.1"]) == "swiftlang-6.4.0.34.1")
        #expect(Toolchain.compilerTag(["compilerVersion": "Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)"]) == "swiftlang-6.4.0.34.1")
        #expect(Toolchain.compilerTag(["compilerVersion": "Swift version 6.4.1 (swift-6.4.1-RELEASE)"]) == "swift-6.4.1-RELEASE")
        #expect(Toolchain.compilerTag([:]) == nil)
    }
}
