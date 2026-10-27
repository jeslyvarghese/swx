import ArgumentParser
import Foundation
import SwxWorkspace

/// `swx self update`: replace this binary with a published release.
struct SelfCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "self",
        abstract: "Manage the swx installation itself.",
        subcommands: [Update.self]
    )

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Update swx to the latest release (or --version), checked against the release's SHA256SUMS.",
            discussion: """
            Replaces the running binary in place, as the install script installed it. Installs made by
            Homebrew or Mint are left to them. $SWX_DOWNLOAD_URL names a mirror of the release assets.
            """
        )

        @Option(help: "A release tag such as v0.4.0 (default: the latest release).")
        var version: String?

        @Flag(help: "Only report whether a newer release exists.")
        var check = false

        func run() async throws {
            let current = SwxCommand.configuration.version
            let updater = SelfUpdate(currentVersion: current)
            let choice: ReleaseChoice = self.version.map(ReleaseChoice.tag) ?? .latest
            let effect: UpdateEffect = self.check ? .check : .install

            let outcome = try await CommandSupport.reportingErrors { try await updater.run(choice, effect: effect) }
            switch outcome {
            case .upToDate(let version):
                print("swx \(version) is the latest release")
            case .available(let version):
                print("swx \(version) is available (this is \(current)); run `swx self update`")
            case .installed(let from, let to, let path):
                print("updated swx \(from) → \(to) at \(path.path)")
            }
        }
    }
}
