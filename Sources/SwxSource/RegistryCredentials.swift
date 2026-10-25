import Foundation
import SwxSystem

/// A login and password (or token) for a host.
public struct Credential: Sendable, Hashable {
    public let login: String
    public let password: String
}

/// Where registry credentials come from after the environment (SwiftPM 6.4 uses exactly one).
public struct CredentialSources: Sendable {
    public enum Store: Sendable {
        /// The macOS Keychain (SwiftPM's default on macOS).
        case keychain
        /// The netrc file (the default on Linux; `--netrc` on macOS).
        case netrc
        /// `--disable-keychain` on macOS: no stored credentials at all.
        case none
    }

    public let netrcFile: URL
    public let store: Store

    private static let defaultNetrc = ".netrc"

    public init(netrcFile: URL?, store: Store) {
        self.netrcFile = netrcFile ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(Self.defaultNetrc)
        self.store = store
    }
}

/// Looks up registry credentials the way SwiftPM does: the registry environment variables,
/// `SWIFTPM_NETRC_DATA`, then the configured store (Keychain or netrc file).
public struct RegistryCredentials: Sendable {
    private enum Environment {
        static let token = "SWIFTPM_REGISTRY_TOKEN"
        static let login = "SWIFTPM_REGISTRY_LOGIN"
        static let password = "SWIFTPM_REGISTRY_PASSWORD"
        static let netrcData = "SWIFTPM_NETRC_DATA"
    }

    /// SwiftPM's environment token provider uses this login; with no configured auth type it
    /// selects bearer authentication.
    public static let tokenLogin = "token"

    private let sources: CredentialSources

    public init(sources: CredentialSources) {
        self.sources = sources
    }

    public func credential(for url: URL) async -> Credential? {
        let environment = ProcessInfo.processInfo.environment

        // Explicit environment credentials apply to every configured registry.
        if let token = environment[Environment.token], !token.isEmpty {
            return Credential(login: Self.tokenLogin, password: token)
        }
        if let login = environment[Environment.login], let password = environment[Environment.password], !login.isEmpty, !password.isEmpty {
            return Credential(login: login, password: password)
        }
        if let data = environment[Environment.netrcData], !data.isEmpty {
            return Netrc(parsing: data).credential(forHost: url.host)
        }

        switch self.sources.store {
        case .keychain:
            return await Keychain.credential(for: url)
        case .netrc:
            guard let contents = FileSystem.readIfPresent(self.sources.netrcFile) else { return nil }
            return Netrc(parsing: String(decoding: contents, as: UTF8.self)).credential(forHost: url.host)
        case .none:
            return nil
        }
    }
}

/// A `.netrc` file: `machine <host> login <user> password <secret>` entries and an optional `default`.
struct Netrc {
    private enum Token {
        static let machine = "machine"
        static let defaultEntry = "default"
        static let login = "login"
        static let password = "password"
        static let account = "account"
        static let macro = "macdef"
    }

    private struct Machine {
        var name: String?
        var login: String?
        var password: String?
    }

    private var machines: [Machine] = []
    private var fallback: Machine?

    init(parsing text: String) {
        var current: Machine?
        var isDefault = false

        func finish() {
            guard let machine = current else { return }
            if isDefault {
                self.fallback = machine
            } else {
                self.machines.append(machine)
            }
            current = nil
        }

        // Macro definitions run to the next blank line; drop them before tokenizing.
        let lines = text.components(separatedBy: .newlines)
        var kept: [String] = []
        var inMacro = false
        for line in lines {
            if inMacro {
                inMacro = !line.trimmingCharacters(in: .whitespaces).isEmpty
                continue
            }
            if line.split(whereSeparator: \.isWhitespace).first == Substring(Token.macro) {
                inMacro = true
                continue
            }
            kept.append(line)
        }

        let tokens = kept.joined(separator: "\n").split(whereSeparator: \.isWhitespace).map(String.init)
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let value = index + 1 < tokens.count ? tokens[index + 1] : nil
            switch token {
            case Token.machine:
                finish()
                current = Machine(name: value?.lowercased())
                isDefault = false
                index += 2
            case Token.defaultEntry:
                finish()
                current = Machine()
                isDefault = true
                index += 1
            case Token.login:
                current?.login = value
                index += 2
            case Token.password:
                current?.password = value
                index += 2
            case Token.account:
                index += 2
            default:
                index += 1
            }
        }
        finish()
    }

    /// SwiftPM matches the host only (no port), preferring the last matching entry, then `default`.
    func credential(forHost host: String?) -> Credential? {
        let host = host?.lowercased()
        let machine = self.machines.last { $0.name != nil && $0.name == host } ?? self.fallback
        guard let login = machine?.login, let password = machine?.password else { return nil }
        return Credential(login: login, password: password)
    }
}

/// Internet passwords in the macOS Keychain, matched by protocol, server and port as SwiftPM does.
enum Keychain {
    private enum Security {
        static let executable = "/usr/bin/security"
        static let findPassword = "find-internet-password"
        static let server = "-s"
        static let port = "-P"
        static let protocolCode = "-r"
        static let passwordOnly = "-w"
        static let accountAttribute = "\"acct\"<blob>="
    }

    /// Four-character protocol codes (`SecProtocolType`).
    private static let protocolCodes = ["https": "htps", "http": "http"]

    static func credential(for url: URL) async -> Credential? {
        #if os(macOS)
        guard let host = url.host, let scheme = url.scheme?.lowercased(), let code = Self.protocolCodes[scheme] else { return nil }
        var query = [Security.executable, Security.findPassword, Security.server, host, Security.protocolCode, code]
        if let port = url.port {
            query += [Security.port, String(port)]
        }

        // One call for the attributes (account), one for the secret.
        guard let attributes = try? await ProcessRunner.run(query, exitPolicy: .allowFailure), attributes.succeeded,
              let password = try? await ProcessRunner.run(query + [Security.passwordOnly], exitPolicy: .allowFailure), password.succeeded,
              let login = Self.account(in: attributes.output) else {
            return nil
        }
        return Credential(login: login, password: password.output.trimmingCharacters(in: .newlines))
        #else
        return nil
        #endif
    }

    /// The `"acct"<blob>="name"` attribute line of `security` output.
    static func account(in output: String) -> String? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(Security.accountAttribute) else { continue }
            let value = trimmed.dropFirst(Security.accountAttribute.count)
            return String(value.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        }
        return nil
    }
}
