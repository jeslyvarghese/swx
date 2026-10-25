// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sample",
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.60.0"),
    ],
    targets: [
        .executableTarget(name: "App", dependencies: [
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            .product(name: "NIOCore", package: "swift-nio"),
        ]),
    ]
)
