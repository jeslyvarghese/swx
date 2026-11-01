#!/usr/bin/env bash
# `swx xcode generate` with an `swx-xcode.json` overlay, end to end (macOS with Xcode).
#
# An AppleProductTypes app with a shared library, a WidgetKit extension and a watchOS companion
# app gets an .xcodeproj; xcodebuild builds it for the iOS simulator, and the app bundle must
# embed the extension (PlugIns) and the watch app (Watch), each with the expected Info.plist and
# entitlements. `swx build --platform ios` builds the same targets through its private project.
#
#   Scripts/check-xcode-overlay.sh [swx-binary]
set -euo pipefail

swx_input="${1:-$(swift build -c release --show-bin-path)/swx}"
readonly swx="$(cd "$(dirname "$swx_input")" && pwd)/$(basename "$swx_input")"
readonly work="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/Lift/Sources/"{LiftApp,Model,LiftWidget,LiftWatch}
cd "$work/Lift"
cat > Package.swift <<'EOF'
// swift-tools-version: 6.0
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "Lift",
    platforms: [.iOS("17.0"), .watchOS("10.0")],
    products: [
        .iOSApplication(
            name: "Lift",
            targets: ["LiftApp"],
            bundleIdentifier: "app.lift.ios",
            teamIdentifier: "",
            displayVersion: "1.0",
            bundleVersion: "3",
            appIcon: .placeholder(icon: .cloud),
            accentColor: .presetColor(.orange),
            supportedDeviceFamilies: [.phone],
            supportedInterfaceOrientations: [.portrait]
        ),
    ],
    targets: [
        .target(name: "Model"),
        .executableTarget(name: "LiftApp", dependencies: ["Model"]),
        .target(name: "LiftWidget", dependencies: ["Model"]),
        .target(name: "LiftWatch", dependencies: ["Model"]),
    ]
)
EOF
cat > swx-xcode.json <<'EOF'
{
  "applications": {
    "Lift": {
      "entitlements": { "com.apple.security.application-groups": ["group.app.lift"] },
      "infoPlist": { "NSSupportsLiveActivities": true }
    }
  },
  "targets": {
    "LiftWidgetExtension": {
      "kind": "widgetExtension",
      "sources": ["LiftWidget"],
      "bundleIdentifier": "app.lift.ios.LiftWidgetExtension",
      "embedIn": "Lift",
      "entitlements": { "com.apple.security.application-groups": ["group.app.lift"] }
    },
    "LiftWatchApp": {
      "kind": "watchApp",
      "sources": ["LiftWatch"],
      "bundleIdentifier": "app.lift.ios.watchkitapp",
      "embedIn": "Lift"
    }
  }
}
EOF
printf 'public let greeting = "lift"\n' > Sources/Model/Model.swift
printf 'import SwiftUI\nimport Model\n@main struct LiftApp: App { var body: some Scene { WindowGroup { Text(greeting) } } }\n' > Sources/LiftApp/App.swift
cat > Sources/LiftWidget/Widget.swift <<'EOF'
#if os(iOS)
import SwiftUI
import WidgetKit
import Model

struct Entry: TimelineEntry { let date: Date }

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) { completion(Timeline(entries: [Entry(date: .now)], policy: .never)) }
}

@main struct LiftWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LiftWidget", provider: Provider()) { _ in Text(greeting) }
    }
}
#endif
EOF
cat > Sources/LiftWatch/WatchApp.swift <<'EOF'
#if os(watchOS)
import SwiftUI
import Model

@main struct LiftWatchApp: App { var body: some Scene { WindowGroup { Text(greeting) } } }
#endif
EOF

"$swx" xcode generate >/dev/null
xcodebuild build -project Lift.xcodeproj -scheme Lift -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO -quiet >/dev/null

app="$(find DerivedData/Build/Products -maxdepth 2 -name Lift.app | head -1)"
test "$(plutil -extract NSSupportsLiveActivities raw "$app/Info.plist")" = true
test "$(plutil -extract CFBundleIdentifier raw "$app/PlugIns/LiftWidgetExtension.appex/Info.plist")" = app.lift.ios.LiftWidgetExtension
test "$(plutil -extract NSExtension.NSExtensionPointIdentifier raw "$app/PlugIns/LiftWidgetExtension.appex/Info.plist")" = com.apple.widgetkit-extension
test "$(plutil -extract WKCompanionAppBundleIdentifier raw "$app/Watch/LiftWatchApp.app/Info.plist")" = app.lift.ios
test "$(plutil -extract com\\.apple\\.security\\.application-groups.0 raw XcodeSupport/Lift.entitlements)" = group.app.lift

# The private project of `swx build --platform ios` reads the same overlay.
rm -rf Lift.xcodeproj XcodeSupport DerivedData
report="$("$swx" build --platform ios --product Lift --format json || true)"
grep -q '"status" *: *"succeeded"' <<<"$report" || { echo "swx build failed: $report" >&2; exit 1; }
test ! -e Lift.xcodeproj

echo "generated Lift.xcodeproj with a widget extension and a watch app; xcodebuild embedded both in Lift.app"
