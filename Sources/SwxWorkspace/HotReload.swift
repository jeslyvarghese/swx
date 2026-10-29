import Foundation
import SwxApple
import SwxBuild
import SwxCore
import SwxDevice
import SwxHotReload
import SwxStore
import SwxSystem

/// `swx run --hot`: runs an app with swx's agent inside, then turns every saved Swift file into a
/// patch the running app loads. Edits a patch can't carry (a type's layout, global state, added
/// files, the manifest) rebuild and relaunch instead. Nothing in the project changes: the build
/// settings go on xcodebuild's command line and the agent comes in through the environment.
extension AppleBuilds {
    private enum HotLayout {
        static let patches = "hot-patches"
        static let swiftExtension = "swift"
    }

    /// How long a launched app has to load the agent and connect.
    private static let agentConnectTimeout = Duration.seconds(30)

    /// Why a watch ended.
    private enum WatchOutcome {
        case appExited
        case relaunch(reason: String)
    }

    private enum WatchEvent {
        case changed([URL])
        case appExited
    }

    /// Builds, launches and keeps reloading until the app exits (or swx is interrupted).
    public func runHot(product: String, target: AppleTarget, configuration: String, arguments: [String], report: @escaping @Sendable (String) -> Void) async throws {
        let destination = try await self.destination(for: target, requirement: .concreteRequired)
        if let runTarget = destination.runTarget, runTarget.environment == .device {
            throw WorkspaceError(description: "hot reload runs apps on simulators and on this Mac for now, not on \(runTarget.name)")
        }

        while true {
            // A hot-reloadable build reports how it compiled each module.
            let build = try await self.build(product: product, target: target, configuration: configuration, action: .build, extraArguments: [], codeLoading: .hotReloadable)
            let modules = build.swiftModules.filter { $0.architecture == Self.hostArchitecture }
            guard let appModule = modules.first(where: { $0.module == product }) ?? modules.first,
                  let triple = appModule.target, let sdk = appModule.sdk else {
                throw WorkspaceError(description: "the build of \(product) logged no Swift compile commands for \(Self.hostArchitecture)")
            }
            let app = build.productsDirectory.appendingPathComponent(product).appendingPathExtension(Self.appExtension)
            guard FileSystem.isDirectory(app) else {
                throw WorkspaceError(description: "built \(product) but found no app bundle at \(app.path)")
            }

            // Launch with the agent for this SDK, listening for it to call back.
            let agent = try await HotReloadAgent.library(target: triple, sdk: sdk, in: self.store.hotReloadAgentsPath)
            let channel = try AgentChannel.listen()
            let launched = try await self.launch(app: app, destination: destination, arguments: arguments, environment: [
                HotReloadAgent.Variable.insertLibraries: agent.path,
                HotReloadAgent.Variable.port: String(channel.port),
            ])
            guard await channel.accept(timeout: Self.agentConnectTimeout) else {
                report("the app didn't load the hot reload agent (hardened runtime?); it runs without hot reload")
                await launched.waitForExit()
                return
            }

            let compiler = PatchCompiler(modules: modules, directory: self.stateDirectory.appendingPathComponent(HotLayout.patches))
            switch await self.watch(compiler: compiler, channel: channel, app: launched, report: report) {
            case .appExited:
                return
            case .relaunch(let reason):
                report("\(reason): rebuilding and relaunching")
                await launched.terminate()
            }
        }
    }

    // MARK: Watching

    /// Patches each saved file into the app until an edit needs a relaunch or the app exits.
    private func watch(compiler: PatchCompiler, channel: AgentChannel, app: LaunchedApp, report: @escaping @Sendable (String) -> Void) async -> WatchOutcome {
        // The package's own files (not checked-out dependencies), their directories and its manifest.
        let root = PatchCompiler.resolved(self.packageDirectory).path + "/"
        let files = compiler.sourceFiles.filter { $0.path.hasPrefix(root) }
        let manifests = [WellKnownFile.manifest, WellKnownFile.packageResolved].map { PatchCompiler.resolved(self.packageDirectory.appendingPathComponent($0)) }
        let directories = Array(Set(files.map { $0.deletingLastPathComponent() })).sorted { $0.path < $1.path }
        let watcher = SourceWatcher(files: files + manifests, directories: directories, fileExtension: HotLayout.swiftExtension)

        // What each file's types look like in the running app.
        var signatures: [URL: LayoutSignature] = [:]
        for file in files {
            signatures[file] = Self.signature(of: file)
        }
        report("hot reload: watching \(files.count) Swift files; saving one reloads it in the app")

        // File changes and the app quitting, in one stream.
        let events = AsyncStream<WatchEvent> { continuation in
            let changes = Task {
                for await changed in watcher.changes() {
                    continuation.yield(.changed(changed))
                }
            }
            let exit = Task {
                await app.waitForExit()
                continuation.yield(.appExited)
                continuation.finish()
            }
            continuation.onTermination = { _ in
                changes.cancel()
                exit.cancel()
            }
        }

        for await event in events {
            guard case .changed(let changed) = event else { return .appExited }
            for file in changed {
                // Anything but an edited Swift file of a module needs the build.
                guard file.pathExtension == HotLayout.swiftExtension, compiler.module(containing: file) != nil, let signature = Self.signature(of: file) else {
                    return .relaunch(reason: "\(file.lastPathComponent) changed")
                }
                if let previous = signatures[file], let reason = signature.reasonToRelaunch(from: previous) {
                    return .relaunch(reason: "\(file.lastPathComponent): \(reason)")
                }

                // Compile, link and load; a compile error waits for the next save.
                let clock = ContinuousClock()
                let start = clock.now
                do {
                    let patch = try await compiler.compile(file)
                    switch try await channel.load(patch) {
                    case .loaded(let functions, _):
                        signatures[file] = signature
                        report("reloaded \(file.lastPathComponent): \(functions) functions in \(Self.seconds(clock.now - start))")
                    case .needsRelaunch(let reason):
                        return .relaunch(reason: "\(file.lastPathComponent): \(reason)")
                    }
                } catch {
                    report("\(file.lastPathComponent) not reloaded:\n\(error)")
                }
            }
        }
        return .appExited
    }

    private static func signature(of file: URL) -> LayoutSignature? {
        FileSystem.readIfPresent(file).map { LayoutSignature(source: String(decoding: $0, as: UTF8.self)) }
    }

    // MARK: Launching

    private func launch(app: URL, destination: ResolvedDestination, arguments: [String], environment: [String: String]) async throws -> LaunchedApp {
        guard let runTarget = destination.runTarget else {
            // Mac apps run in place.
            let executable = try Self.infoValue(Self.executableKey, in: app, platform: .macOS)
            let path = app.appendingPathComponent(Self.macOSContents).appendingPathComponent(Self.macOSExecutables).appendingPathComponent(executable)
            return try DeviceRunner.launchOnMac(executable: path, arguments: arguments, environment: environment)
        }
        let bundleIdentifier = try Self.infoValue(Self.bundleIdentifierKey, in: app, platform: destination.destination.platform)
        return try await DeviceRunner.launch(app: app, bundleIdentifier: bundleIdentifier, on: runTarget, arguments: arguments, environment: environment)
    }

    /// Simulators run the Mac's architecture; patches are compiled for it.
    private static var hostArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    private static func seconds(_ duration: Duration) -> String {
        let milliseconds = duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
        return String(format: "%.2f s", Double(milliseconds) / 1000)
    }
}
