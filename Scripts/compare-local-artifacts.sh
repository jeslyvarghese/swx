#!/usr/bin/env bash
# Differential check of local binary targets against SwiftPM: a root package with an
# XCFramework directory and a zipped one, and a path dependency with its own zip. SwiftPM and
# swx resolve copies of it; workspace-state.json (path, kind, checksum of each artifact) and the
# extracted files in .build/artifacts must match, again after an unchanged re-resolve and after
# the zip changes in place.
#
#   Scripts/compare-local-artifacts.sh [swx-binary]
set -euo pipefail

swx_input="${1:-$(swift build -c release --show-bin-path)/swx}"
readonly swx="$(cd "$(dirname "$swx_input")" && pwd)/$(basename "$swx_input")"
readonly work="$(cd "$(mktemp -d)" && pwd -P)"
trap 'status=$?; chmod -R u+w "$work"; rm -rf "$work"; exit $status' EXIT
export SWX_CACHE_DIR="$work/store"

fail() {
    echo "compare-local-artifacts: $*" >&2
    exit 1
}

# A minimal XCFramework: SwiftPM recognizes one by the libraries its Info.plist lists.
make_xcframework() {
    local directory="$1" marker="$2"
    mkdir -p "$directory"
    cat > "$directory/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>AvailableLibraries</key><array/><key>CFBundlePackageType</key><string>XFWK</string><key>XCFrameworkFormatVersion</key><string>1.0</string></dict></plist>
PLIST
    echo "$marker" > "$directory/marker.txt"
}

# The package: Root (an XCFramework directory and a zip) depends on Dep (another zip).
readonly source="$work/source"
mkdir -p "$source/Root/Sources/Root" "$source/Root/Frameworks" "$source/Dep/Sources/Dep" "$source/Dep/Binaries"
make_xcframework "$source/Root/Frameworks/Plain.xcframework" plain
make_xcframework "$work/zip/Zipped.xcframework" zipped-1
(cd "$work/zip" && zip -qry "$source/Root/Frameworks/Zipped.xcframework.zip" Zipped.xcframework)
make_xcframework "$work/dep-zip/Wrapper/DepKit.xcframework" dep
(cd "$work/dep-zip" && zip -qry "$source/Dep/Binaries/DepKit.zip" Wrapper)
echo 'public let root = 1' > "$source/Root/Sources/Root/Root.swift"
echo 'public let dep = 1' > "$source/Dep/Sources/Dep/Dep.swift"
cat > "$source/Root/Package.swift" <<'EOF'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Root", dependencies: [.package(path: "../Dep")],
  targets: [
    .target(name: "Root", dependencies: ["Plain", "Zipped", .product(name: "Dep", package: "Dep")]),
    .binaryTarget(name: "Plain", path: "Frameworks/Plain.xcframework"),
    .binaryTarget(name: "Zipped", path: "Frameworks/Zipped.xcframework.zip"),
  ])
EOF
cat > "$source/Dep/Package.swift" <<'EOF'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Dep", products: [.library(name: "Dep", targets: ["Dep"])],
  targets: [.target(name: "Dep", dependencies: ["DepKit"]), .binaryTarget(name: "DepKit", path: "Binaries/DepKit.zip")])
EOF

# State with the copy's path replaced, artifacts in a fixed order (SwiftPM's within a package isn't).
canonical_state() {
    python3 -I -c 'import json, sys
state = json.load(open(sys.argv[1]))
state["object"]["artifacts"].sort(key=lambda a: (a["packageRef"]["identity"], a["targetName"]))
print(json.dumps(state, indent=2, sort_keys=True).replace(sys.argv[2], "ROOT"))' "$1" "$2"
}

# Resolves each tool's copy and compares what they wrote.
resolve_and_compare() {
    local label="$1"
    (cd "$work/spm/Root" && swift package resolve --cache-path "$work/spm-cache" >/dev/null 2>&1) || fail "$label: SwiftPM failed"
    (cd "$work/swx/Root" && "$swx" package resolve -q) || fail "$label: swx failed"
    diff <(canonical_state "$work/spm/Root/.build/workspace-state.json" "$work/spm") <(canonical_state "$work/swx/Root/.build/workspace-state.json" "$work/swx") \
        || fail "$label: workspace-state.json differs"
    diff -r "$work/spm/Root/.build/artifacts" "$work/swx/Root/.build/artifacts" -x extract || fail "$label: .build/artifacts differs"
    echo "$label: state and extracted artifacts match SwiftPM's"
}

for tool in spm swx; do
    cp -R "$source" "$work/$tool"
done
resolve_and_compare "first resolve"

# The same zip again: nothing to extract. A changed zip: the new contents and checksum.
resolve_and_compare "unchanged archive"
rm -rf "$work/zip" && make_xcframework "$work/zip/Zipped.xcframework" zipped-2
for tool in spm swx; do
    rm "$work/$tool/Root/Frameworks/Zipped.xcframework.zip"
    (cd "$work/zip" && zip -qry "$work/$tool/Root/Frameworks/Zipped.xcframework.zip" Zipped.xcframework)
done
resolve_and_compare "changed archive"
grep -q zipped-2 "$work/swx/Root/.build/artifacts/root/Zipped/Zipped.xcframework/marker.txt" || fail "the changed archive wasn't extracted"
