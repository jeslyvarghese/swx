// swift-tools-version: 6.0
// A macro and a library using it: swift-syntax is host-only, so prebuilts replace it.
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "Macros",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "604.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .macro(name: "Mac", dependencies: [
            .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
        ]),
        .target(name: "Lib", dependencies: ["Mac"]),
        .executableTarget(name: "App", dependencies: ["Lib", .product(name: "ArgumentParser", package: "swift-argument-parser")]),
        .testTarget(name: "MacTests", dependencies: ["Mac", .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax")]),
    ]
)
