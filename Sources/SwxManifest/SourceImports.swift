import SwiftParser
import SwiftSyntax

/// The modules a Swift source file imports.
public enum SourceImports {
    /// Top-level module names of every `import` (`import struct A.B` counts as `A`), in every
    /// `#if` branch: code that only builds on some platforms still needs its dependencies declared.
    public static func modules(in source: String) -> Set<String> {
        let visitor = ImportVisitor(viewMode: .sourceAccurate)
        visitor.walk(Parser.parse(source: source))
        return visitor.modules
    }
}

private final class ImportVisitor: SyntaxVisitor {
    var modules: Set<String> = []

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        if let module = node.path.first?.name.text {
            self.modules.insert(module)
        }
        return .skipChildren
    }

    // Imports never appear inside declarations' bodies; skip them for speed.
    override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

    override func visit(_ node: MemberBlockSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }
}
