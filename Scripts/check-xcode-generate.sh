#!/usr/bin/env bash
# `swx xcode generate` end to end (macOS with Xcode).
#
# A dynamic AppleProductTypes app (targets built in a loop, an internal target using an
# external product) gets an .xcodeproj; `swx xcode resolve` prepares its packages, xcodebuild
# builds it offline, and the app's Info.plist must carry the manifest's settings.
#
#   Scripts/check-xcode-generate.sh [swx-binary]
set -euo pipefail

swx_input="${1:-$(swift build -c release --show-bin-path)/swx}"
readonly swx="$(cd "$(dirname "$swx_input")" && pwd)/$(basename "$swx_input")"
readonly work="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/HelloApp/Sources/HelloApp" "$work/HelloApp/Sources/Core"
cd "$work/HelloApp"
cat > Package.swift <<'EOF'
// swift-tools-version: 5.9
import PackageDescription
import AppleProductTypes

let features = ["Core"]
var targets: [Target] = features.map { .target(name: $0, dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser")]) }
targets.append(.executableTarget(name: "HelloApp", dependencies: features.map { .target(name: $0) }))

let package = Package(
    name: "HelloApp",
    platforms: [.iOS("17.0")],
    products: [
        .iOSApplication(
            name: "HelloApp",
            targets: ["HelloApp"],
            bundleIdentifier: "com.example.generated",
            teamIdentifier: "",
            displayVersion: "2.3",
            bundleVersion: "45",
            appIcon: .placeholder(icon: .cloud),
            accentColor: .presetColor(.blue),
            supportedDeviceFamilies: [.pad, .phone],
            supportedInterfaceOrientations: [.portrait, .landscapeLeft]
        ),
    ],
    dependencies: [.package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")],
    targets: targets
)
EOF
printf 'import ArgumentParser\npublic let core = 1\n' > Sources/Core/Core.swift
printf 'import SwiftUI\nimport Core\n@main struct HelloApp: App { var body: some Scene { WindowGroup { Text("\\(core)") } } }\n' > Sources/HelloApp/App.swift

"$swx" xcode generate >/dev/null
"$swx" xcode resolve --project HelloApp.xcodeproj --source-packages SourcePackages >/dev/null
xcodebuild build -project HelloApp.xcodeproj -scheme HelloApp -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath DerivedData -clonedSourcePackagesDirPath SourcePackages \
    -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO -quiet >/dev/null

info="$(find DerivedData/Build/Products -maxdepth 2 -name HelloApp.app | head -1)/Info.plist"
test "$(plutil -extract CFBundleIdentifier raw "$info")" = com.example.generated
test "$(plutil -extract CFBundleShortVersionString raw "$info")" = 2.3
test "$(plutil -extract CFBundleVersion raw "$info")" = 45
test "$(plutil -extract UIDeviceFamily json -o - "$info")" = "[1,2]"
echo "generated HelloApp.xcodeproj; resolved with swx, built offline; Info.plist carries the manifest's settings"
