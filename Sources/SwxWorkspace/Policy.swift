import Foundation
import SwxCore
import SwxGraph
import SwxSystem

public typealias AuditPolicy = SwxGraph.AuditPolicy
public typealias AdvisorySeverity = SwxGraph.AdvisorySeverity
public typealias OutdatedPolicy = SwxGraph.OutdatedPolicy
public typealias OutdatedThreshold = SwxGraph.OutdatedThreshold
public typealias OutdatedEntry = SwxGraph.OutdatedEntry

/// A package's checks policy, from `.swx/policy.json`:
///
///     {
///       "audit": { "ignore": ["GHSA-…"], "failOn": "high" },
///       "outdated": { "ignore": ["swift-nio"], "failOn": "wanted" }
///     }
public struct Policy: Sendable, Equatable {
    public var audit = AuditPolicy()
    public var outdated = OutdatedPolicy()

    public init(audit: AuditPolicy = AuditPolicy(), outdated: OutdatedPolicy = OutdatedPolicy()) {
        self.audit = audit
        self.outdated = outdated
    }

    /// Where the policy lives, relative to the package.
    public static let relativePath = ".swx/policy.json"

    private struct File: Decodable {
        struct Section<Threshold: Decodable>: Decodable {
            var ignore: [String]?
            var failOn: Threshold?
        }

        var audit: Section<AdvisorySeverity>?
        var outdated: Section<OutdatedThreshold>?
    }

    /// `.swx/policy.json: audit.failOn: …`, naming the field at fault.
    private static func invalid(_ context: DecodingError.Context) -> WorkspaceError {
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return WorkspaceError(description: "\(Self.relativePath): \(path.isEmpty ? "" : path + ": ")\(context.debugDescription)")
    }

    /// The policy in `data`; absent fields keep their defaults.
    public static func decode(_ data: Data) throws -> Policy {
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: data)
        } catch let DecodingError.dataCorrupted(context) {
            throw Self.invalid(context)
        } catch let DecodingError.typeMismatch(_, context) {
            throw Self.invalid(context)
        } catch {
            throw WorkspaceError(description: "\(Self.relativePath) is invalid: \(error.localizedDescription)")
        }

        var policy = Policy()
        policy.audit.ignore = Set(file.audit?.ignore ?? [])
        policy.audit.failOn = file.audit?.failOn ?? policy.audit.failOn
        policy.outdated.ignore = Set((file.outdated?.ignore ?? []).map { $0.lowercased() })
        policy.outdated.failOn = file.outdated?.failOn ?? policy.outdated.failOn
        return policy
    }
}

extension Workspace {
    /// The package's `.swx/policy.json`, or the defaults when there is none.
    public func policy() throws -> Policy {
        guard case .package(let directory) = self.options.root,
              let data = FileSystem.readIfPresent(directory.appendingPathComponent(Policy.relativePath)) else {
            return Policy()
        }
        return try Policy.decode(data)
    }
}
