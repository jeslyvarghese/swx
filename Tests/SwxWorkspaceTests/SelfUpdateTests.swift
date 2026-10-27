import Foundation
@testable import SwxWorkspace
import Testing

struct SelfUpdateTests {
    /// `sha256sum` output: one `<hex>  <name>` line per asset.
    @Test func readsChecksums() {
        let sums = """
        aaa1  swx-linux-aarch64.tar.gz
        bbb2  swx-linux-x86_64.tar.gz
        ccc3  swx-macos-universal.tar.gz

        """
        #expect(SelfUpdate.checksum(of: "swx-linux-x86_64.tar.gz", in: sums) == "bbb2")
        #expect(SelfUpdate.checksum(of: "swx-macos-universal.tar.gz", in: sums) == "ccc3")
        #expect(SelfUpdate.checksum(of: "swx-windows.zip", in: sums) == nil)
    }

    @Test func readsVersionsFromTags() {
        #expect(SelfUpdate.version(fromTag: "v0.5.0") == "0.5.0")
        #expect(SelfUpdate.version(fromTag: "0.5.0") == "0.5.0")
    }

    /// Homebrew's and Mint's installs are theirs to update.
    @Test func leavesManagedInstallsAlone() async {
        let brew = SelfUpdate(currentVersion: "0.4.0", executable: URL(fileURLWithPath: "/opt/homebrew/Cellar/swx/0.4.0/bin/swx"))
        await #expect(throws: SelfUpdateError.self) { try await brew.run(.latest, effect: .check) }
    }

    /// A mirror can't answer "which release is latest".
    @Test func needsATagWithAMirror() async {
        let mirrored = SelfUpdate(currentVersion: "0.4.0", executable: URL(fileURLWithPath: "/usr/local/bin/swx"), environment: ["SWX_DOWNLOAD_URL": "https://mirror.example.com/swx"])
        await #expect(throws: SelfUpdateError.self) { try await mirrored.run(.latest, effect: .check) }
    }
}
