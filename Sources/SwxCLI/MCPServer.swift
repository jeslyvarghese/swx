import ArgumentParser
import Foundation
import SwxWorkspace

/// `swx mcp`: swx as a Model Context Protocol server over stdio, so agents call typed tools
/// (build, test, hot reload, screenshot) instead of composing command lines.
///
/// Each tool runs this same binary with `--format json` and hands back its report: the CLI
/// and the server can't drift apart.
struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve swx's commands as MCP tools over stdio (claude mcp add swx -- swx mcp)."
    )

    func run() async throws {
        await MCPServer().serve()
    }
}

/// JSON-RPC 2.0 over newline-delimited stdin/stdout, as MCP's stdio transport specifies.
struct MCPServer {
    private enum Method {
        static let initialize = "initialize"
        static let ping = "ping"
        static let listTools = "tools/list"
        static let callTool = "tools/call"
    }

    private enum RPCError {
        static let parse = -32700
        static let methodNotFound = -32601
        static let invalidParams = -32602
    }

    /// Protocol revisions this server speaks; the client's choice wins when it is one of them.
    private static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    private static let jsonRPCVersion = "2.0"
    private static let serverName = "swx"

    private let output = MCPOutput()

    func serve() async {
        await withTaskGroup(of: Void.self) { group in
            // Requests run concurrently: a long build doesn't hold up a ping.
            while let line = readLine(strippingNewline: true) {
                guard !line.isEmpty else { continue }
                group.addTask {
                    await self.handle(line)
                }
            }
        }
    }

    private func handle(_ line: String) async {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else {
            await self.output.send(Self.error(id: .null, code: RPCError.parse, message: "not JSON"))
            return
        }

        // Notifications (no id) get no answer.
        guard let id = message["id"], let method = message["method"]?.string else { return }
        let params = message["params"] ?? .object([:])

        switch method {
        case Method.initialize:
            let requested = params["protocolVersion"]?.string
            let version = requested.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0]
            await self.output.send(Self.result(id: id, .object([
                "protocolVersion": .string(version),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string(Self.serverName), "version": .string(SwxCommand.configuration.version)]),
                "instructions": .string(AgentGuide.text),
            ])))
        case Method.ping:
            await self.output.send(Self.result(id: id, .object([:])))
        case Method.listTools:
            await self.output.send(Self.result(id: id, .object(["tools": .array(MCPTools.all.map(\.definition))])))
        case Method.callTool:
            guard let name = params["name"]?.string, let tool = MCPTools.all.first(where: { $0.name == name }) else {
                await self.output.send(Self.error(id: id, code: RPCError.invalidParams, message: "unknown tool"))
                return
            }
            let content = await tool.call(params["arguments"] ?? .object([:]))
            await self.output.send(Self.result(id: id, content))
        default:
            await self.output.send(Self.error(id: id, code: RPCError.methodNotFound, message: "method not found: \(method)"))
        }
    }

    private static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string(Self.jsonRPCVersion), "id": id, "result": result])
    }

    private static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object(["jsonrpc": .string(Self.jsonRPCVersion), "id": id, "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }
}

/// One message per line on stdout, never interleaved.
private actor MCPOutput {
    func send(_ message: JSONValue) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard var data = try? encoder.encode(message) else { return }
        data.append(UInt8(ascii: "\n"))
        FileHandle.standardOutput.write(data)
    }
}

/// A tool: its schema, and the swx command line its arguments turn into.
struct MCPTool: Sendable {
    let name: String
    let description: String
    let properties: [String: JSONValue]
    let required: [String]
    let command: @Sendable (JSONValue) -> [String]
    /// How long the command may take before it is stopped.
    let timeout: Duration
    let result: Result

    enum Result: Sendable {
        /// swx's JSON report, as text.
        case report
        /// The screenshot the report names, as an image (and the report).
        case image
    }

    var definition: JSONValue {
        .object([
            "name": .string(self.name),
            "description": .string(self.description),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object(self.properties),
                "required": .array(self.required.map(JSONValue.string)),
            ]),
        ])
    }

    private static let formatArguments = [OutputFormat.option, OutputFormat.json.rawValue]
    private static let pngMimeType = "image/png"
    private static let errorTailLines = 20

    func call(_ arguments: JSONValue) async -> JSONValue {
        let command = self.command(arguments) + Self.formatArguments
        guard let result = try? await SelfInvocation.run(command, timeout: self.timeout) else {
            return Self.content([.text("could not run swx \(command.joined(separator: " "))")], isError: true)
        }

        // The report, or what swx printed when there is none.
        var report = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if report.isEmpty {
            report = result.errors.split(separator: "\n").suffix(Self.errorTailLines).joined(separator: "\n")
        }
        if result.timedOut {
            report += "\n(stopped after \(self.timeout))"
        }
        let isError = result.exitCode != 0 || result.timedOut

        // A screenshot comes back as the image itself.
        guard self.result == .image, !isError,
              let path = (try? JSONDecoder().decode(JSONValue.self, from: Data(report.utf8)))?["path"]?.string,
              let image = FileManager.default.contents(atPath: path) else {
            return Self.content([.text(report)], isError: isError)
        }
        return Self.content([.image(image.base64EncodedString(), Self.pngMimeType), .text(report)], isError: false)
    }

    private enum Content {
        case text(String)
        case image(String, String)
    }

    private static func content(_ items: [Content], isError: Bool) -> JSONValue {
        let content: [JSONValue] = items.map { item in
            switch item {
            case .text(let text):
                return .object(["type": .string("text"), "text": .string(text)])
            case .image(let data, let mimeType):
                return .object(["type": .string("image"), "data": .string(data), "mimeType": .string(mimeType)])
            }
        }
        return .object(["content": .array(content), "isError": .bool(isError)])
    }
}

/// swx's tools.
enum MCPTools {
    private static let buildTimeout = Duration.seconds(3600)
    private static let quickTimeout = Duration.seconds(120)
    private static let runTimeout = 60.0
    private static let screenshotSize = 1200

    // Schema pieces.
    private static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func boolean(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    private static func number(_ description: String) -> JSONValue {
        .object(["type": .string("number"), "description": .string(description)])
    }

    private static func strings(_ description: String) -> JSONValue {
        .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string(description)])
    }

    private static let packagePath = Self.string("The package directory (or the directory holding the Xcode project). Default: the server's working directory.")
    private static let platform = Self.string("ios, tvos, watchos, visionos or macos: build with xcodebuild for that platform. Omit for a host (SwiftPM) build.")
    private static let device = Self.string("A simulator (or device) name or identifier; see swx_devices. Default: a booted simulator, else the newest.")
    private static let product = Self.string("The product (scheme) to build, or the app to run.")
    private static let configuration = Self.string("debug (default) or release.")
    private static let extra = Self.strings("More arguments for `swift build|test|run`, or xcodebuild with a platform.")

    // Arguments to command-line options.
    private static func option(_ name: String, _ key: String, in arguments: JSONValue) -> [String] {
        guard let value = arguments[key]?.scalarString else { return [] }
        return [name, value]
    }

    private static func flag(_ name: String, _ key: String, in arguments: JSONValue) -> [String] {
        arguments[key]?.bool == true ? [name] : []
    }

    private static func list(_ key: String, in arguments: JSONValue) -> [String] {
        arguments[key]?.array?.compactMap(\.scalarString) ?? []
    }

    private static func common(_ arguments: JSONValue) -> [String] {
        Self.option("--package-path", "package_path", in: arguments)
    }

    private static func apple(_ arguments: JSONValue) -> [String] {
        Self.option("--platform", "platform", in: arguments)
            + Self.option("--device", "device", in: arguments)
            + Self.option("--configuration", "configuration", in: arguments)
    }

    static let all: [MCPTool] = [
        MCPTool(
            name: "swx_resolve",
            description: "Resolve the package's dependencies (respecting Package.resolved), or update them to the newest allowed versions. Returns the packages and what changed.",
            properties: ["package_path": Self.packagePath, "update": Self.boolean("Update to the newest versions the requirements allow.")],
            required: [],
            command: { [($0["update"]?.bool == true ? "update" : "resolve")] + Self.common($0) },
            timeout: Self.buildTimeout,
            result: .report
        ),
        MCPTool(
            name: "swx_add",
            description: "Add a package dependency (URL, owner/repo on GitHub, or a Swift Package Index name, optionally @version) and use one of its products in a target; then resolve.",
            properties: [
                "package_path": Self.packagePath,
                "package": Self.string("A URL, owner/repo, or package name, optionally with @version (swift-nio@2.60.0)."),
                "product": Self.string("The product to use (default: the package's only library, or the one named like it)."),
                "target": Self.string("The target that uses it (default: the package's only non-test target)."),
                "exact": Self.boolean("Require exactly @version."),
                "branch": Self.string("Track a branch instead of releases."),
            ],
            required: ["package"],
            command: { arguments in
                ["add", arguments["package"]?.scalarString ?? ""]
                    + Self.option("--product", "product", in: arguments)
                    + Self.option("--target", "target", in: arguments)
                    + Self.option("--branch", "branch", in: arguments)
                    + Self.flag("--exact", "exact", in: arguments)
                    + Self.common(arguments)
            },
            timeout: Self.buildTimeout,
            result: .report
        ),
        MCPTool(
            name: "swx_build",
            description: "Build the package (swift build), or an Apple app with a platform (xcodebuild). Returns status and the compiler's errors and warnings with file, line and column; the full log's path is included.",
            properties: ["package_path": Self.packagePath, "platform": Self.platform, "product": Self.product, "device": Self.device, "configuration": Self.configuration, "arguments": Self.extra],
            required: [],
            command: { arguments in
                ["build"] + Self.apple(arguments) + Self.option("--product", "product", in: arguments) + Self.list("arguments", in: arguments) + Self.common(arguments)
            },
            timeout: Self.buildTimeout,
            result: .report
        ),
        MCPTool(
            name: "swx_test",
            description: "Run the tests (swift test, or on a simulator with a platform). Returns passed, failed and skipped counts, and each failing test with its issues (file, line, message), plus build errors if it didn't build.",
            properties: [
                "package_path": Self.packagePath, "platform": Self.platform, "device": Self.device, "configuration": Self.configuration,
                "filter": Self.string("Only tests matching this (swift test --filter; host builds)."),
                "arguments": Self.extra,
            ],
            required: [],
            command: { arguments in
                ["test"] + Self.apple(arguments) + Self.option("--filter", "filter", in: arguments) + Self.list("arguments", in: arguments) + Self.common(arguments)
            },
            timeout: Self.buildTimeout,
            result: .report
        ),
        MCPTool(
            name: "swx_run",
            description: "Build and run an executable product and return its output (stopped after timeout_seconds). With a platform, builds the app and launches it on a simulator or this Mac in the background; prefer swx_hot_start for apps you are editing.",
            properties: [
                "package_path": Self.packagePath, "platform": Self.platform, "device": Self.device, "configuration": Self.configuration,
                "product": Self.product,
                "arguments": Self.strings("Arguments for the program."),
                "timeout_seconds": Self.number("Stop the program after this long (default 60)."),
            ],
            required: [],
            command: { arguments in
                let timeout = arguments["timeout_seconds"]?.scalarString ?? String(Int(Self.runTimeout))
                let program = arguments["product"]?.scalarString.map { [$0] } ?? []
                let platform = Self.apple(arguments)
                let timeoutOption = platform.isEmpty ? [Run.timeoutOption, timeout] : []
                return ["run"] + platform + timeoutOption + Self.common(arguments) + program + Self.list("arguments", in: arguments)
            },
            timeout: Self.buildTimeout,
            result: .report
        ),
        MCPTool(
            name: "swx_devices",
            description: "List simulators and paired devices: platform, OS version, name, identifier, booted.",
            properties: [:],
            required: [],
            command: { _ in ["devices"] },
            timeout: Self.quickTimeout,
            result: .report
        ),
        MCPTool(
            name: "swx_hot_start",
            description: "Build an app, launch it on a simulator (or this Mac) and hot reload it in the background: every saved Swift file is patched into the running app in about a second, keeping its state. Returns once the app runs. Then edit files and call swx_hot_status.",
            properties: ["package_path": Self.packagePath, "platform": Self.platform, "product": Self.string("The app product."), "device": Self.device, "configuration": Self.configuration],
            required: ["platform", "product"],
            command: { arguments in
                ["hot", "start"] + Self.apple(arguments) + Self.common(arguments) + [arguments["product"]?.scalarString ?? ""]
            },
            timeout: Self.buildTimeout,
            result: .report
        ),
        MCPTool(
            name: "swx_hot_status",
            description: "What the hot reload session did with your saves: each event is reloaded (new code running), not-reloaded (compile error, with diagnostics), relaunching (layout change; rebuilt) or build-failed. By default waits until every save so far was handled.",
            properties: ["package_path": Self.packagePath, "wait": Self.boolean("Wait until every save so far was handled (default true).")],
            required: [],
            command: { arguments in
                ["hot", "status"] + (arguments["wait"]?.bool == false ? [] : ["--wait"]) + Self.common(arguments)
            },
            timeout: Self.buildTimeout,
            result: .report
        ),
        MCPTool(
            name: "swx_hot_logs",
            description: "The hot reload session's output: the app's console (print, os_log to stdout) and swx's messages.",
            properties: ["package_path": Self.packagePath, "lines": Self.number("How many of the last lines (default 100).")],
            required: [],
            command: { ["hot", "logs"] + Self.option("--lines", "lines", in: $0) + Self.common($0) },
            timeout: Self.quickTimeout,
            result: .report
        ),
        MCPTool(
            name: "swx_hot_stop",
            description: "Quit the app and end the hot reload session.",
            properties: ["package_path": Self.packagePath],
            required: [],
            command: { ["hot", "stop"] + Self.common($0) },
            timeout: Self.quickTimeout,
            result: .report
        ),
        MCPTool(
            name: "swx_screenshot",
            description: "A screenshot of the running app (the hot reload session's simulator or Mac window, a named simulator, or the only booted one), returned as an image to look at.",
            properties: [
                "package_path": Self.packagePath, "device": Self.device,
                "max_dimension": Self.number("Scale down so the longer side is at most this many pixels (default 1200)."),
            ],
            required: [],
            command: { arguments in
                let size = arguments["max_dimension"]?.scalarString ?? String(Self.screenshotSize)
                return ["screenshot", "--max-dimension", size] + Self.option("--device", "device", in: arguments) + Self.common(arguments)
            },
            timeout: Self.quickTimeout,
            result: .image
        ),
        MCPTool(
            name: "swx_outdated",
            description: "Dependencies with newer versions: pinned, wanted (what the requirements allow) and latest.",
            properties: ["package_path": Self.packagePath],
            required: [],
            command: { ["outdated"] + Self.common($0) },
            timeout: Self.buildTimeout,
            result: .report
        ),
    ]
}

extension JSONValue {
    subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var bool: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var array: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    /// Strings as they are, whole numbers without a fraction: values for command-line options.
    var scalarString: String? {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value.rounded() == value ? String(Int(value)) : String(value)
        case .bool(let value):
            return String(value)
        default:
            return nil
        }
    }
}
