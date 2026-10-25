#!/usr/bin/env bash
# Differential check for dynamic AppleProductTypes manifests (macOS with Xcode).
#
# The fixture app's manifest computes its targets with a loop, so the static parser declines
# it and swx compiles it against Xcode's ManifestAPI. Package.resolved must match what
# `xcodebuild -resolvePackageDependencies` writes, and xcodebuild must see the app scheme.
#
#   Scripts/compare-apple-manifest.sh [swx-binary]
set -euo pipefail

swx_input="${1:-$(swift build -c release --show-bin-path)/swx}"
readonly swx="$(cd "$(dirname "$swx_input")" && pwd)/$(basename "$swx_input")"
readonly work="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$work"' EXIT

make_app() {
    local directory="$1"
    mkdir -p "$directory/Sources/HelloApp" "$directory/Sources/Core"
    cat > "$directory/Package.swift" <<'EOF'
// swift-tools-version: 5.9
import PackageDescription
import AppleProductTypes

let features = ["Core"]
var targets: [Target] = features.map { .target(name: $0) }
targets.append(.executableTarget(name: "HelloApp", dependencies: features.map { .target(name: $0) }))

let package = Package(
    name: "HelloApp",
    platforms: [.iOS("17.0")],
    products: [
        .iOSApplication(
            name: "HelloApp",
            targets: ["HelloApp"],
            bundleIdentifier: "com.example.hello",
            teamIdentifier: "",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .cloud),
            accentColor: .presetColor(.blue),
            supportedDeviceFamilies: [.pad, .phone],
            supportedInterfaceOrientations: [.portrait]
        ),
    ],
    dependencies: [.package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")],
    targets: targets
)
EOF
    echo 'public let core = 1' > "$directory/Sources/Core/Core.swift"
    printf 'import SwiftUI\n@main struct HelloApp: App { var body: some Scene { WindowGroup { Text("hi") } } }\n' > "$directory/Sources/HelloApp/App.swift"
}

make_app "$work/xcode/HelloApp.swiftpm"
make_app "$work/swx/HelloApp.swiftpm"

(cd "$work/xcode/HelloApp.swiftpm" && xcodebuild -resolvePackageDependencies -scheme HelloApp -clonedSourcePackagesDirPath "$work/xcode/SourcePackages" >/dev/null 2>&1)
(cd "$work/swx/HelloApp.swiftpm" && SWX_TRACE=1 "$swx" package resolve --cache-path "$work/cache" > "$work/trace" 2>&1)
grep -q "manifest: Xcode ManifestAPI" "$work/trace"
diff "$work/xcode/HelloApp.swiftpm/Package.resolved" "$work/swx/HelloApp.swiftpm/Package.resolved"
echo "dynamic app manifest evaluated through Xcode's ManifestAPI; Package.resolved identical to Xcode's"

(cd "$work/swx/HelloApp.swiftpm" && xcodebuild -list > "$work/schemes" 2>/dev/null)
grep -q "HelloApp" "$work/schemes"
echo "xcodebuild lists the HelloApp scheme"
