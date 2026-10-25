import Foundation
import SwxSystem

/// Tag listing over git's smart HTTP protocol v2 (`ls-refs`), without starting `git`.
///
/// One POST per repository on a connection URLSession reuses across a host's repositories.
/// Any failure (private repository, an old server, a redirect to a login page) returns `nil`,
/// and the caller falls back to `git ls-remote`.
public enum GitHTTP {
    /// For `swx debug tag-parity`: both listings, as `name revision` lines.
    public static func compareWithGit(url: String) async throws -> (http: [String]?, git: [String]) {
        let http = await Self.listTags(url: url).map { $0.map { "\($0.name) \($0.revision)" } }
        let result = try await ProcessRunner.run(["git", "ls-remote", "--tags", url])
        let git = GitRepository.parseTags(result.output).map { "\($0.name) \($0.revision)" }
        return (http, git)
    }

    private enum Header {
        static let protocolVersion = "Git-Protocol"
        static let protocolValue = "version=2"
        static let contentType = "Content-Type"
        static let accept = "Accept"
        static let request = "application/x-git-upload-pack-request"
        static let result = "application/x-git-upload-pack-result"
    }

    private enum Command {
        static let lsRefs = "command=ls-refs\n"
        static let agent = "agent=swx\n"
        static let peel = "peel\n"
        static let tagsPrefix = "ref-prefix refs/tags/\n"
    }

    private enum PacketLine {
        static let flush = "0000"
        static let delimiter = "0001"
        static let responseEnd = "0002"
        static let lengthDigits = 4
    }

    private static let uploadPack = "git-upload-pack"
    private static let httpsScheme = "https"
    private static let gitSuffix = ".git"
    private static let tagsPrefix = "refs/tags/"
    private static let peeledPrefix = "peeled:"
    private static let ok = 200

    /// `SWX_GIT_HTTP=0` always uses `git ls-remote`.
    private static let optOutVariable = "SWX_GIT_HTTP"
    private static let optOutValue = "0"

    static func listTags(url: String) async -> [RemoteTag]? {
        guard ProcessInfo.processInfo.environment[Self.optOutVariable] != Self.optOutValue,
              let endpoint = Self.endpoint(for: url) else {
            return nil
        }
        let body = Self.packetLine(Command.lsRefs) + Self.packetLine(Command.agent)
            + PacketLine.delimiter + Self.packetLine(Command.peel) + Self.packetLine(Command.tagsPrefix) + PacketLine.flush
        let headers = [
            Header.protocolVersion: Header.protocolValue,
            Header.contentType: Header.request,
            Header.accept: Header.result,
        ]
        guard let response = try? await HTTP.post(endpoint, body: Data(body.utf8), headers: headers),
              response.status == Self.ok else {
            return nil
        }
        return Self.parse(response.body)
    }

    /// `https://host/owner/repo[.git]` → `…/repo.git/git-upload-pack`; other schemes use `git`.
    static func endpoint(for url: String) -> URL? {
        guard var components = URLComponents(string: url), components.scheme == Self.httpsScheme,
              components.user == nil, components.password == nil else {
            return nil
        }
        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        if !path.hasSuffix(Self.gitSuffix) {
            path += Self.gitSuffix
        }
        components.path = path + "/" + Self.uploadPack
        return components.url
    }

    /// `<length><payload>`, the length in four hex digits including itself.
    static func packetLine(_ payload: String) -> String {
        let length = payload.utf8.count + PacketLine.lengthDigits
        let hex = String(length, radix: 16)
        return String(repeating: "0", count: PacketLine.lengthDigits - hex.count) + hex + payload
    }

    /// Lines `<oid> refs/tags/<name>[ peeled:<oid>]`; annotated tags resolve to their commit.
    /// Returns `nil` when the response is not a well-formed ref listing.
    static func parse(_ data: Data) -> [RemoteTag]? {
        let bytes = [UInt8](data)
        var tags: [RemoteTag] = []
        var cursor = 0
        while cursor + PacketLine.lengthDigits <= bytes.count {
            guard let lengthText = String(bytes: bytes[cursor..<(cursor + PacketLine.lengthDigits)], encoding: .ascii),
                  let length = Int(lengthText, radix: 16) else {
                return nil
            }

            // Flush and response-end close the listing; a delimiter never appears in ls-refs output.
            if lengthText == PacketLine.flush || lengthText == PacketLine.responseEnd {
                return tags
            }
            guard length > PacketLine.lengthDigits, cursor + length <= bytes.count else { return nil }
            let payload = String(decoding: bytes[(cursor + PacketLine.lengthDigits)..<(cursor + length)], as: UTF8.self)
            cursor += length

            let fields = payload.trimmingCharacters(in: .newlines).split(separator: " ")
            guard fields.count >= 2, fields[1].hasPrefix(Self.tagsPrefix) else { return nil }
            let name = String(fields[1].dropFirst(Self.tagsPrefix.count))
            let peeled = fields.dropFirst(2).first { $0.hasPrefix(Self.peeledPrefix) }.map { String($0.dropFirst(Self.peeledPrefix.count)) }
            tags.append(RemoteTag(name: name, revision: peeled ?? String(fields[0])))
        }
        return nil
    }
}
