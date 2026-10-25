#!/usr/bin/env bash
# Registry packages in an Xcode project, against xcodebuild (macOS with Xcode).
#
# A project (generated with XcodeGen through `swx tool run`) holds a local package folder that
# depends on a registry package served by Scripts/test-registry.py. Xcode reads the registry
# configuration from the workspace's xcshareddata/swiftpm/configuration. xcodebuild and
# `swx xcode resolve` run in the same directory; Package.resolved, SourcePackages state and the
# registry download (with .registry-metadata) must be identical.
#
# xcodebuild has no security-path or cache-path option, so it records the fixture's
# fingerprints in ~/.swiftpm/security and caches its download in
# ~/Library/Caches/org.swift.swiftpm/registry/downloads; the script removes both again (the
# test-only `swxtest` scope), the fingerprints only if they did not exist before.
#
#   Scripts/compare-xcode-registry.sh [swx-binary]
set -euo pipefail

swx_input="${1:-$(swift build -c release --show-bin-path)/swx}"
readonly swx="$(cd "$(dirname "$swx_input")" && pwd)/$(basename "$swx_input")"
readonly root="$(cd "$(dirname "$0")/.." && pwd)"
readonly work="$(cd "$(mktemp -d)" && pwd -P)"
readonly identity="swxtest.RegistryKit"
readonly xcodeFingerprints="$HOME/.swiftpm/security/fingerprints/$identity.json"
readonly xcodeDownloads="$HOME/Library/Caches/org.swift.swiftpm/registry/downloads/swxtest"
fingerprintsExisted=no
[ -e "$xcodeFingerprints" ] && fingerprintsExisted=yes
server=""
cleanup() {
    [ -n "$server" ] && kill "$server" 2>/dev/null
    [ "$fingerprintsExisted" = no ] && rm -f "$xcodeFingerprints"
    rm -rf "$xcodeDownloads" "$work"
}
trap cleanup EXIT
rm -rf "$xcodeDownloads"

# The registry package.
release="$work/packages/swxtest/RegistryKit/1.1.0"
mkdir -p "$release/Sources/RegistryKit"
printf '// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: "RegistryKit", products: [.library(name: "RegistryKit", targets: ["RegistryKit"])], targets: [.target(name: "RegistryKit")])\n' > "$release/Package.swift"
echo 'public let kit = 1' > "$release/Sources/RegistryKit/RegistryKit.swift"
python3 -I "$root/Scripts/test-registry.py" --root "$work/packages" > "$work/port" &
server=$!
# The server prints its port once every archive is built: slow runners need well over 5 s.
for _ in $(seq 600); do [ -s "$work/port" ] && break; kill -0 "$server" 2>/dev/null || break; sleep 0.1; done
[ -s "$work/port" ] || { echo "the test registry did not start" >&2; exit 1; }
readonly port="$(cat "$work/port")"

# The project: a tool target using a local package that depends on the registry package.
mkdir -p "$work/project/App" "$work/project/Shared/Sources/Shared"
cd "$work/project"
cat > Shared/Package.swift <<EOF
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Shared", products: [.library(name: "Shared", targets: ["Shared"])],
  dependencies: [.package(id: "$identity", from: "1.0.0")],
  targets: [.target(name: "Shared", dependencies: [.product(name: "RegistryKit", package: "$identity")])])
EOF
echo 'import RegistryKit; public let shared = kit' > Shared/Sources/Shared/Shared.swift
echo 'import Shared; print(shared)' > App/main.swift
cat > project.yml <<'EOF'
name: Reg
packages:
  Shared: {path: Shared}
targets:
  Tool:
    type: tool
    platform: macOS
    sources: [App]
    dependencies: [{package: Shared}]
EOF
"$swx" tool run yonaskolb/XcodeGen generate --spec project.yml >/dev/null
readonly shared="Reg.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$shared/configuration"
echo "{\"registries\": {\"[default]\": {\"supportsAvailability\": false, \"url\": \"http://127.0.0.1:$port\"}}, \"version\": 1}" > "$shared/configuration/registries.json"

# xcodebuild first, then swx in the same place.
xcodebuild -resolvePackageDependencies -project Reg.xcodeproj -scheme Tool -clonedSourcePackagesDirPath "$work/project/SourcePackages" >/dev/null 2>&1
cp "$shared/Package.resolved" "$work/xcode-resolved.json"
cp SourcePackages/workspace-state.json "$work/xcode-state.json"
cp -R SourcePackages/registry "$work/xcode-registry"
rm -rf SourcePackages "$shared/Package.resolved"

"$swx" xcode resolve --source-packages SourcePackages --security-path "$work/swx-security" >/dev/null
diff "$work/xcode-resolved.json" "$shared/Package.resolved"
diff "$work/xcode-state.json" SourcePackages/workspace-state.json
# xcodebuild also leaves its own .swiftpm scheme data inside packages it opens.
diff -r -x .swiftpm "$work/xcode-registry/downloads" SourcePackages/registry/downloads
echo "registry package in an Xcode project: Package.resolved, state and download identical to xcodebuild"
