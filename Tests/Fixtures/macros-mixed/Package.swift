// swift-tools-version: 6.0
// A macro, and a library product that uses SwiftParser itself: swift-syntax is needed for the
// destination too, so SwiftPM keeps it in the graph.
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "MacrosMixed",
    platforms: [.macOS(.v13)],
    products: [.library(name: "Parsing", targets: ["Parsing"])],
    dependencies: [.package(url: "https://github.com/swiftlang/swift-syntax.git", from: "604.0.0")],
    targets: [
        .macro(name: "Mac", dependencies: [.product(name: "SwiftSyntaxMacros", package: "swift-syntax"), .product(name: "SwiftCompilerPlugin", package: "swift-syntax")]),
        .target(name: "Parsing", dependencies: ["Mac", .product(name: "SwiftParser", package: "swift-syntax")]),
    ]
)
