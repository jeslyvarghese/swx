#!/usr/bin/env bash
# Generated Xcode projects link a package's own library products (macOS with Xcode).
#
# An AppleProductTypes app imports an internal library that depends on GRDB (whose SQLite
# system-library module a translated static library can't see) and reads a resource through
# `Bundle.module`. The library is vended by a `.library` product, so the generated project links
# it as a local package product: `swx xcode generate` + xcodebuild and `swx build --platform ios`
# must both build, at the package's declared iOS 26.0 minimum, with the resource bundle embedded.
#
#   Scripts/check-xcode-package-products.sh [swx-binary]
set -euo pipefail

swx_input="${1:-$(swift build -c release --show-bin-path)/swx}"
readonly swx="$(cd "$(dirname "$swx_input")" && pwd)/$(basename "$swx_input")"
readonly work="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/Fix/Sources/"{FixApp,Store/Resources}
cd "$work/Fix"
cat > Package.swift <<'EOF'
// swift-tools-version: 6.0
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "Fix",
    platforms: [.iOS("26.0")],
    products: [
        .iOSApplication(
            name: "Fix",
            targets: ["FixApp"],
            bundleIdentifier: "app.fix.ios",
            teamIdentifier: "",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .cloud),
            accentColor: .presetColor(.orange),
            supportedDeviceFamilies: [.phone],
            supportedInterfaceOrientations: [.portrait]
        ),
        .library(name: "Store", targets: ["Store"]),
    ],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1")],
    targets: [
        .target(name: "Store", dependencies: [.product(name: "GRDB", package: "GRDB.swift")], resources: [.copy("Resources/greeting.txt")]),
        .executableTarget(name: "FixApp", dependencies: ["Store"]),
    ]
)
EOF
printf 'hello\n' > Sources/Store/Resources/greeting.txt
cat > Sources/Store/Store.swift <<'EOF'
import Foundation
import GRDB

public func greeting() throws -> String {
    let queue = try DatabaseQueue()
    let url = Bundle.module.url(forResource: "greeting", withExtension: "txt")!
    let text = try String(contentsOf: url, encoding: .utf8)
    return try queue.read { db in try String.fetchOne(db, sql: "SELECT ?", arguments: [text]) ?? "" }
}
EOF
printf 'import SwiftUI\nimport Store\n@main struct FixApp: App { var body: some Scene { WindowGroup { Text((try? greeting()) ?? "") } } }\n' > Sources/FixApp/App.swift

# The project next to the package references it as a local package at ".".
"$swx" xcode generate >/dev/null
grep -q 'XCLocalSwiftPackageReference "."' Fix.xcodeproj/project.pbxproj
grep -q 'IPHONEOS_DEPLOYMENT_TARGET = 26.0' Fix.xcodeproj/project.pbxproj
xcodebuild build -project Fix.xcodeproj -scheme Fix -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO -quiet >/dev/null

app="$(find DerivedData/Build/Products -maxdepth 2 -name Fix.app | head -1)"
test -f "$app/Fix_Store.bundle/greeting.txt"

# The private project of `swx build --platform ios` links the product the same way.
rm -rf Fix.xcodeproj DerivedData
report="$("$swx" build --platform ios --product Fix --format json || true)"
grep -q '"status" *: *"succeeded"' <<<"$report" || { echo "swx build failed: $report" >&2; exit 1; }
test ! -e Fix.xcodeproj

echo "linked Store as a local package product: GRDB's system module and Bundle.module resources build, at iOS 26.0"
