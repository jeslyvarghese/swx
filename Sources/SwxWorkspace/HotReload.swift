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

    /// Builds, launches and keeps reloading until the app exits, or the task is cancelled
    /// (which quits the app and throws `CancellationError`). A failed build waits for the next
    /// save and builds again.
    public func runHot(product: String, target: AppleTarget, configuration: String, arguments: [String], observe: @escaping @Sendable (HotEvent) -> Void) async throws {
        let destination = try await self.destination(for: target, requirement: .concreteRequired)
        if let runTarget = destination.runTarget, runTarget.environment == .device {
            throw WorkspaceError(description: "hot reload runs apps on simulators and on this Mac for now, not on \(runTarget.name)", code: .unsupportedDestination, fix: "pass --destination simulator, or --platform macos")
        }

        while true {
            // A hot-reloadable build reports how it compiled each module.
            observe(.building)
            let build: BuildResult
            do {
                build = try await self.build(product: product, target: target, configuration: configuration, action: .build, extraArguments: [], codeLoading: .hotReloadable)
            } catch let error as BuildError {
                try await self.waitForFix(after: error, observe: observe)
                continue
            }
            try Task.checkCancellation()

            let modules = build.swiftModules.filter { $0.architecture == Self.hostArchitecture }
            guard let appModule = modules.first(where: { $0.module == product }) ?? modules.first,
                  let triple = appModule.target, let sdk = appModule.sdk else {
                throw WorkspaceError(description: "the build of \(product) logged no Swift compile commands for \(Self.hostArchitecture)", code: .hotReload)
            }
            let app = build.productsDirectory.appendingPathComponent(product).appendingPathExtension(Self.appExtension)
            guard FileSystem.isDirectory(app) else {
                throw WorkspaceError(description: "built \(product) but found no app bundle at \(app.path)", code: .noAppBundle, fix: "pass an app product (an .iOSApplication or an app target) to run")
            }

            // Launch with the agent for this SDK, listening for it to call back.
            let agent = try await HotReloadAgent.library(target: triple, sdk: sdk, in: self.store.hotReloadAgentsPath)
            let channel = try AgentChannel.listen()
            let launched = try await self.launch(app: app, destination: destination, arguments: arguments, environment: [
                HotReloadAgent.Variable.insertLibraries: agent.path,
                HotReloadAgent.Variable.port: String(channel.port),
            ])
            observe(.launched(
                device: destination.runTarget?.identifier,
                deviceName: destination.runTarget?.name,
                appProcess: destination.runTarget == nil ? launched.processIdentifier : nil
            ))
            guard await channel.accept(timeout: Self.agentConnectTimeout) else {
                observe(.agentMissing)
                await launched.waitForExit()
                try await Self.endIfCancelled(launched)
                observe(.exited)
                return
            }

            let compiler = PatchCompiler(modules: modules, directory: self.stateDirectory.appendingPathComponent(HotLayout.patches))
            let outcome = await self.watch(compiler: compiler, channel: channel, app: launched, observe: observe)
            try await Self.endIfCancelled(launched)
            switch outcome {
            case .appExited:
                observe(.exited)
                return
            case .relaunch(let reason):
                observe(.relaunching(reason: reason))
                await launched.terminate()
            }
        }
    }

    /// How long a stopped run may take to quit its app before the process exits anyway (a
    /// build in progress doesn't stop when asked).
    private static let stopGrace = 10.0

    /// `runHot`, ended by SIGINT or SIGTERM (Ctrl-C, `swx hot stop`) too: the app quits with it.
    public func runHotUntilStopped(product: String, target: AppleTarget, configuration: String, arguments: [String], observe: @escaping @Sendable (HotEvent) -> Void) async throws {
        let run = Task {
            try await self.runHot(product: product, target: target, configuration: configuration, arguments: arguments, observe: observe)
        }
        let signals = ProcessControl.onTermination {
            run.cancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopGrace) {
                observe(.stopped)
                exit(EXIT_SUCCESS)
            }
        }
        defer { withExtendedLifetime(signals) {} }

        do {
            try await run.value
        } catch is CancellationError {
            observe(.stopped)
        }
    }

    /// A cancelled run quits the app before it ends.
    private static func endIfCancelled(_ app: LaunchedApp) async throws {
        guard Task.isCancelled else { return }
        await app.terminate()
        throw CancellationError()
    }

    /// Reports a failed build and returns once one of the package's files changes.
    private func waitForFix(after error: BuildError, observe: @escaping @Sendable (HotEvent) -> Void) async throws {
        let log = error.log.flatMap(FileSystem.readIfPresent).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let files = self.packageSwiftFiles()
        let manifests = [WellKnownFile.manifest, WellKnownFile.packageResolved].map { PatchCompiler.resolved(self.packageDirectory.appendingPathComponent($0)) }
        let directories = Array(Set(files.map { $0.deletingLastPathComponent() })).sorted { $0.path < $1.path }
        observe(.buildFailed(message: error.description, diagnostics: BuildLog.diagnostics(in: log), log: error.log, watching: files + manifests))

        let watcher = SourceWatcher(files: files + manifests, directories: directories, fileExtension: HotLayout.swiftExtension)
        for await _ in watcher.changes() {
            return
        }
        throw CancellationError()
    }

    /// The package's own Swift files, outside `.build` and hidden directories.
    private func packageSwiftFiles() -> [URL] {
        let root = PatchCompiler.resolved(self.packageDirectory)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == WellKnownFile.buildDirectory {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension == HotLayout.swiftExtension, url.lastPathComponent != WellKnownFile.manifest {
                files.append(PatchCompiler.resolved(url))
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    // MARK: Watching

    /// Patches each saved file into the app until an edit needs a relaunch or the app exits.
    private func watch(compiler: PatchCompiler, channel: AgentChannel, app: LaunchedApp, observe: @escaping @Sendable (HotEvent) -> Void) async -> WatchOutcome {
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
        observe(.watching(files: files + manifests))

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
                        observe(.reloaded(file: file, functions: functions, seconds: Self.seconds(clock.now - start)))
                    case .needsRelaunch(let reason):
                        return .relaunch(reason: "\(file.lastPathComponent): \(reason)")
                    }
                } catch {
                    observe(.notReloaded(file: file, error: String(describing: error)))
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

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
