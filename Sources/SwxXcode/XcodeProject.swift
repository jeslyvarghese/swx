import Foundation
import SwxCore
import SwxSystem

/// A Swift package dependency declared in an Xcode project (`XCRemoteSwiftPackageReference`
/// or `XCLocalSwiftPackageReference`).
public struct XcodePackageReference: Sendable, Hashable {
    public enum Location: Sendable, Hashable {
        case remote(url: String)
        case local(path: String)
    }

    public let location: Location
    public let requirement: Requirement

    /// The string SwiftPM hashes into `originHash` for this dependency.
    public var locationString: String {
        switch self.location {
        case .remote(let url):
            return url
        case .local(let path):
            return path
        }
    }
}

/// The package-related facts of an `.xcodeproj` or `.xcworkspace`.
public struct XcodeProject: Sendable {
    public let name: String
    public let packageReferences: [XcodePackageReference]
    /// Package folders placed in the project (or workspace) itself: Xcode makes them roots of
    /// the package graph, like SwiftPM's root package, rather than dependencies.
    public let rootPackages: [URL]
    /// Where Xcode keeps the shared `Package.resolved`.
    public let resolvedFile: URL

    /// What Xcode hashes into `originHash`: each root package's manifest, then reference
    /// locations ordered by package identity (verified against xcodebuild).
    public func originHashContent(rootManifests: [String]) -> String {
        rootManifests.joined() + Self.originHashContent(self.packageReferences)
    }

    public static func originHashContent(_ references: [XcodePackageReference]) -> String {
        references.map(\.locationString)
            .sorted { PackageIdentity(location: $0) < PackageIdentity(location: $1) }
            .joined()
    }
}

public struct XcodeProjectError: Error, CustomStringConvertible {
    public let description: String
}

/// Reads Xcode projects and workspaces.
public enum XcodeProjectReader {
    private enum Extension {
        static let project = "xcodeproj"
        static let workspace = "xcworkspace"
    }

    private enum Path {
        static let projectFile = "project.pbxproj"
        static let embeddedWorkspace = "project.xcworkspace"
        static let sharedData = "xcshareddata"
        static let swiftPM = "swiftpm"
        static let workspaceContents = "contents.xcworkspacedata"
    }

    private enum ObjectKey {
        static let objects = "objects"
        static let rootObject = "rootObject"
        static let packageReferences = "packageReferences"
        static let isa = "isa"
        static let repositoryURL = "repositoryURL"
        static let requirement = "requirement"
        static let relativePath = "relativePath"
        static let kind = "kind"
        static let minimumVersion = "minimumVersion"
        static let maximumVersion = "maximumVersion"
        static let version = "version"
        static let branch = "branch"
        static let revision = "revision"
    }

    private enum ObjectType {
        static let remotePackage = "XCRemoteSwiftPackageReference"
        static let localPackage = "XCLocalSwiftPackageReference"
    }

    private enum RequirementKind {
        static let upToNextMajor = "upToNextMajorVersion"
        static let upToNextMinor = "upToNextMinorVersion"
        static let exact = "exactVersion"
        static let range = "versionRange"
        static let branch = "branch"
        static let revision = "revision"
    }

    /// `group:App.xcodeproj` / `container:App.xcodeproj` locations in workspace XML.
    private static let fileReferencePattern = #"location\s*=\s*"(?:group|container|absolute):([^"]+)""#

    /// Reads a project or workspace at `url`.
    public static func read(_ url: URL) async throws -> XcodeProject {
        switch url.pathExtension {
        case Extension.project:
            let contents = try await Self.contents(ofProject: url)
            let resolved = url.appendingPathComponent(Path.embeddedWorkspace)
                .appendingPathComponent(Path.sharedData)
                .appendingPathComponent(Path.swiftPM)
                .appendingPathComponent(WellKnownFile.packageResolved)
            return XcodeProject(
                name: url.deletingPathExtension().lastPathComponent,
                packageReferences: contents.references,
                rootPackages: contents.rootPackages,
                resolvedFile: resolved
            )

        case Extension.workspace:
            // A workspace resolves the union of its projects' packages, pinned in its own shared data.
            let members = try Self.members(ofWorkspace: url)
            var references: [XcodePackageReference] = []
            var rootPackages = members.packages
            for project in members.projects {
                let contents = try await Self.contents(ofProject: project)
                for reference in contents.references where !references.contains(reference) {
                    references.append(reference)
                }
                for package in contents.rootPackages where !rootPackages.contains(package) {
                    rootPackages.append(package)
                }
            }
            let resolved = url.appendingPathComponent(Path.sharedData)
                .appendingPathComponent(Path.swiftPM)
                .appendingPathComponent(WellKnownFile.packageResolved)
            return XcodeProject(name: url.deletingPathExtension().lastPathComponent, packageReferences: references, rootPackages: rootPackages, resolvedFile: resolved)

        default:
            throw XcodeProjectError(description: "\(url.path) is not an .xcodeproj or .xcworkspace")
        }
    }

    /// Finds the single project or workspace in a directory (workspaces win, like xcodebuild).
    public static func locate(in directory: URL) throws -> URL {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        if let workspace = entries.first(where: { $0.hasSuffix("." + Extension.workspace) }) {
            return directory.appendingPathComponent(workspace)
        }
        if let project = entries.first(where: { $0.hasSuffix("." + Extension.project) }) {
            return directory.appendingPathComponent(project)
        }
        throw XcodeProjectError(description: "no .xcodeproj or .xcworkspace in \(directory.path)")
    }

    // MARK: Projects

    /// Package references and root package folders of one project.
    struct ProjectContents {
        let references: [XcodePackageReference]
        let rootPackages: [URL]
    }

    static func packageReferences(inProject project: URL) async throws -> [XcodePackageReference] {
        try await Self.contents(ofProject: project).references
    }

    static func contents(ofProject project: URL) async throws -> ProjectContents {
        // `plutil` reads the OpenStep plist format of project.pbxproj.
        let projectFile = project.appendingPathComponent(Path.projectFile)
        let result = try await ProcessRunner.run(["plutil", "-convert", "json", "-o", "-", projectFile.path])
        guard let json = try JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any],
              let objects = json[ObjectKey.objects] as? [String: [String: Any]] else {
            throw XcodeProjectError(description: "unreadable \(projectFile.path)")
        }

        // Xcode hashes references in the project's `packageReferences` order; fall back to sorted ids.
        let rootObject = (json[ObjectKey.rootObject] as? String).flatMap { objects[$0] }
        let ordered = rootObject?[ObjectKey.packageReferences] as? [String] ?? objects.keys.sorted()

        var references: [XcodePackageReference] = []
        for identifier in ordered {
            guard let object = objects[identifier] else { continue }
            switch object[ObjectKey.isa] as? String {
            case ObjectType.remotePackage:
                guard let url = object[ObjectKey.repositoryURL] as? String else { continue }
                let requirement = try Self.requirement(object[ObjectKey.requirement] as? [String: Any] ?? [:], url: url)
                references.append(XcodePackageReference(location: .remote(url: url), requirement: requirement))
            case ObjectType.localPackage:
                guard let relative = object[ObjectKey.relativePath] as? String else { continue }
                // Xcode's form: symlinks resolved and `/private` stripped (`/tmp/…`, not `/private/tmp/…`).
                let path = project.deletingLastPathComponent().appendingPathComponent(relative).resolvingSymlinksInPath().path
                references.append(XcodePackageReference(location: .local(path: path), requirement: .unversioned))
            default:
                continue
            }
        }
        let projectDirectory = project.deletingLastPathComponent()
        return ProjectContents(references: references, rootPackages: Self.rootPackages(objects: objects, rootObject: rootObject, projectDirectory: projectDirectory))
    }

    // MARK: Root packages

    private enum GroupKey {
        static let mainGroup = "mainGroup"
        static let children = "children"
        static let path = "path"
        static let sourceTree = "sourceTree"
        static let fileType = "lastKnownFileType"
    }

    private enum SourceTree {
        static let group = "<group>"
        static let absolute = "<absolute>"
        static let projectRoot = "SOURCE_ROOT"
    }

    /// File types Xcode gives a package folder dragged into the project.
    private static let folderTypes: Set<String> = ["folder", "wrapper"]

    /// Folder references that contain a `Package.swift`, in the project navigator's order.
    static func rootPackages(objects: [String: [String: Any]], rootObject: [String: Any]?, projectDirectory: URL) -> [URL] {
        guard let mainGroup = rootObject?[GroupKey.mainGroup] as? String else { return [] }
        var packages: [URL] = []

        // Walk the navigator tree depth-first, resolving each item's path against its group.
        func visit(_ identifier: String, parent: URL) {
            guard let object = objects[identifier], let location = Self.location(of: object, parent: parent, projectDirectory: projectDirectory) else { return }
            if let type = object[GroupKey.fileType] as? String, Self.folderTypes.contains(type),
               FileSystem.exists(location.appendingPathComponent(WellKnownFile.manifest)) {
                packages.append(location.standardizedFileURL)
                return
            }
            for child in object[GroupKey.children] as? [String] ?? [] {
                visit(child, parent: location)
            }
        }
        visit(mainGroup, parent: projectDirectory)
        return packages
    }

    /// An item's location: relative to its group, the project, or absolute; nil for build-time trees.
    private static func location(of object: [String: Any], parent: URL, projectDirectory: URL) -> URL? {
        let path = object[GroupKey.path] as? String
        switch object[GroupKey.sourceTree] as? String ?? SourceTree.group {
        case SourceTree.group:
            return path.map { parent.appendingPathComponent($0) } ?? parent
        case SourceTree.projectRoot:
            return path.map { projectDirectory.appendingPathComponent($0) } ?? projectDirectory
        case SourceTree.absolute:
            return path.map { URL(fileURLWithPath: $0) }
        default:
            return nil
        }
    }

    /// Maps Xcode's requirement kinds onto SwiftPM requirements.
    static func requirement(_ json: [String: Any], url: String) throws -> Requirement {
        func version(_ key: String) throws -> Version {
            guard let text = json[key] as? String, let version = Version(text) else {
                throw XcodeProjectError(description: "invalid \(key) for \(url)")
            }
            return version
        }

        switch json[ObjectKey.kind] as? String {
        case RequirementKind.upToNextMajor:
            let minimum = try version(ObjectKey.minimumVersion)
            return .version(.range(VersionRange(minimum, Version(minimum.major + 1, 0, 0))))
        case RequirementKind.upToNextMinor:
            let minimum = try version(ObjectKey.minimumVersion)
            return .version(.range(VersionRange(minimum, Version(minimum.major, minimum.minor + 1, 0))))
        case RequirementKind.exact:
            return .version(.exact(try version(ObjectKey.version)))
        case RequirementKind.range:
            return .version(.range(VersionRange(try version(ObjectKey.minimumVersion), try version(ObjectKey.maximumVersion))))
        case RequirementKind.branch:
            guard let branch = json[ObjectKey.branch] as? String else { break }
            return .branch(branch)
        case RequirementKind.revision:
            guard let revision = json[ObjectKey.revision] as? String else { break }
            return .revision(revision)
        default:
            break
        }
        throw XcodeProjectError(description: "unsupported package requirement for \(url): \(json)")
    }

    // MARK: Workspaces

    static func projects(inWorkspace workspace: URL) throws -> [URL] {
        try Self.members(ofWorkspace: workspace).projects
    }

    /// A workspace's projects, and the package folders it lists directly (roots, as in projects).
    static func members(ofWorkspace workspace: URL) throws -> (projects: [URL], packages: [URL]) {
        let contents = try String(contentsOf: workspace.appendingPathComponent(Path.workspaceContents), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: Self.fileReferencePattern)
        let range = NSRange(contents.startIndex..., in: contents)

        // Relative locations are relative to the workspace's directory.
        var projects: [URL] = []
        var packages: [URL] = []
        for match in regex.matches(in: contents, range: range) {
            guard let pathRange = Range(match.range(at: 1), in: contents) else { continue }
            let path = String(contents[pathRange])
            let url = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : workspace.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
            if url.pathExtension == Extension.project {
                projects.append(url)
            } else if FileSystem.exists(url.appendingPathComponent(WellKnownFile.manifest)) {
                packages.append(url)
            }
        }
        return (projects, packages)
    }
}
