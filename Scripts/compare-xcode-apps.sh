#!/usr/bin/env bash
# Xcode projects with a watch app and an app extension, plus a local package folder as root.
#
# Generates the project with XcodeGen (run through `swx tool run`), then:
#   1. resolves it with xcodebuild and with `swx xcode resolve` in the same directory and
#      compares Package.resolved and SourcePackages/workspace-state.json byte for byte,
#   2. builds the iOS app (embedding the watch app and widget) with `swx build --platform ios`,
#   3. runs the watch app on a watchOS simulator with `swx run --platform watchos`.
#
#   Scripts/compare-xcode-apps.sh [swx-binary]
set -euo pipefail

swx_input="${1:-$(swift build -c release --show-bin-path)/swx}"
readonly swx="$(cd "$(dirname "$swx_input")" && pwd)/$(basename "$swx_input")"
readonly work="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$work"' EXIT
readonly resolved="Multi.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

mkdir -p "$work/App" "$work/Watch" "$work/Widget" "$work/Shared/Sources/Shared"
cd "$work"

cat > Shared/Package.swift <<'EOF'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Shared",
    platforms: [.iOS(.v17), .watchOS(.v10)],
    products: [.library(name: "Shared", targets: ["Shared"])],
    dependencies: [.package(url: "https://github.com/apple/swift-collections", from: "1.1.0")],
    targets: [.target(name: "Shared", dependencies: [.product(name: "OrderedCollections", package: "swift-collections")])]
)
EOF
cat > Shared/Sources/Shared/Shared.swift <<'EOF'
import OrderedCollections
public enum Greeting { public static var text: String { OrderedSet(["Hello", "watch"]).joined(separator: ", ") } }
EOF
cat > App/App.swift <<'EOF'
import SwiftUI
import Shared
@main struct MultiApp: App { var body: some Scene { WindowGroup { Text(Greeting.text) } } }
EOF
cat > Watch/WatchApp.swift <<'EOF'
import SwiftUI
import Shared
@main struct WatchApp: App { var body: some Scene { WindowGroup { Text(Greeting.text) } } }
EOF
cat > Widget/Widget.swift <<'EOF'
import WidgetKit
import SwiftUI
import Shared
struct Entry: TimelineEntry { let date: Date }
struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) { completion(Timeline(entries: [Entry(date: .now)], policy: .never)) }
}
@main struct GreetingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Greeting", provider: Provider()) { _ in Text(Greeting.text) }
    }
}
EOF
cat > project.yml <<'EOF'
name: Multi
options:
  deploymentTarget: {iOS: "17.0", watchOS: "10.0"}
packages:
  Shared: {path: Shared}
targets:
  MultiApp:
    type: application
    platform: iOS
    sources: [App]
    dependencies:
      - package: Shared
      - target: GreetingWidget
      - target: WatchApp
    info: {path: App/Info.plist, properties: {UILaunchScreen: {}}}
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: com.example.multi
      CODE_SIGNING_ALLOWED: "NO"
  GreetingWidget:
    type: app-extension
    platform: iOS
    sources: [Widget]
    dependencies: [{package: Shared}]
    info: {path: Widget/Info.plist, properties: {NSExtension: {NSExtensionPointIdentifier: com.apple.widgetkit-extension}}}
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: com.example.multi.widget
      CODE_SIGNING_ALLOWED: "NO"
  WatchApp:
    type: application
    platform: watchOS
    sources: [Watch]
    dependencies: [{package: Shared}]
    info: {path: Watch/Info.plist, properties: {WKApplication: true, WKCompanionAppBundleIdentifier: com.example.multi}}
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: com.example.multi.watchkitapp
      CODE_SIGNING_ALLOWED: "NO"
schemes:
  MultiApp:
    build: {targets: {MultiApp: all}}
  WatchApp:
    build: {targets: {WatchApp: all}}
EOF
"$swx" tool run yonaskolb/XcodeGen generate --spec project.yml >/dev/null

# 1. Resolution, compared with xcodebuild in the same directory (paths are part of the files).
xcodebuild -resolvePackageDependencies -project Multi.xcodeproj -scheme MultiApp -clonedSourcePackagesDirPath "$work/SourcePackages" >/dev/null 2>&1
cp "$resolved" "$work/xcode-resolved.json"
cp SourcePackages/workspace-state.json "$work/xcode-state.json"
rm -rf "$work/SourcePackages" "$resolved"
"$swx" xcode resolve --source-packages SourcePackages >/dev/null
diff "$work/xcode-resolved.json" "$resolved"
diff "$work/xcode-state.json" SourcePackages/workspace-state.json
echo "resolution identical to xcodebuild (local package folder treated as a root)"

# 2. The iOS app embeds the widget and the watch app.
"$swx" build --platform ios --product MultiApp >/dev/null 2>&1
app="$(find .build/swx-xcode/DerivedData/Build/Products -maxdepth 2 -name MultiApp.app | head -1)"
test -d "$app/PlugIns/GreetingWidget.appex"
test -d "$app/Watch/WatchApp.app"
echo "built MultiApp.app with PlugIns/GreetingWidget.appex and Watch/WatchApp.app"

# 3–4. The watch app and the iOS app launch on their simulators. Once launched, `swx run`
# hands over to `simctl launch --console-pty … <bundle id>` to stream the console; stop it there.
launch() {
    local platform="$1" product="$2" bundle="$3" log="$work/$2.log"
    "$swx" run --platform "$platform" "$product" > "$log" 2>&1 &
    local runner=$!
    local launched=""
    for _ in $(seq 200); do
        if pgrep -f "simctl launch .* $bundle\$" >/dev/null; then
            launched=yes
            break
        fi
        kill -0 "$runner" 2>/dev/null || break
        sleep 2
    done
    pkill -f "simctl launch .* $bundle\$" 2>/dev/null || true
    kill "$runner" 2>/dev/null || true
    if [ -z "$launched" ]; then
        echo "$product did not launch:" >&2
        tail -20 "$log" >&2
        exit 1
    fi
    echo "$product launched on a $platform simulator"
}
launch watchos WatchApp com.example.multi.watchkitapp
launch ios MultiApp com.example.multi
