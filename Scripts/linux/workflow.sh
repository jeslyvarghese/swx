#!/usr/bin/env bash
# Runs inside a Linux Swift image: compares swx with SwiftPM on a sample package and
# exercises run, scripts and tools. Expects the swx binary at $SWX and fixtures in /work.
set -euo pipefail

readonly swx="${SWX:-/swx/swx}"
readonly work=/work
mkdir -p /tmp/spm /tmp/swx
cp -R "$work/Package.swift" "$work/Sources" /tmp/spm/
cp -R "$work/Package.swift" "$work/Sources" /tmp/swx/

# Resolution must match SwiftPM byte for byte (paths aside).
(cd /tmp/spm && swift package resolve >/dev/null)
(cd /tmp/swx && "$swx" package resolve)
diff /tmp/spm/Package.resolved /tmp/swx/Package.resolved
diff <(sed 's#/tmp/spm#R#g' /tmp/spm/.build/workspace-state.json) <(sed 's#/tmp/swx#R#g' /tmp/swx/.build/workspace-state.json)
echo "resolution identical"

# Binary artifacts: the same entries as SwiftPM, and a second project reuses the store.
cat > /tmp/artifacts-manifest.swift <<'MANIFEST'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Lint",
    dependencies: [.package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", exact: "0.59.1")],
    targets: [.target(name: "Lib")]
)
MANIFEST
for dir in /tmp/art-spm /tmp/art-swx /tmp/art-swx2; do
    mkdir -p "$dir/Sources/Lib"
    cp /tmp/artifacts-manifest.swift "$dir/Package.swift"
    echo 'public let value = 1' > "$dir/Sources/Lib/Lib.swift"
done
(cd /tmp/art-spm && swift package resolve >/dev/null)
(cd /tmp/art-swx && "$swx" package resolve)
diff <(sed 's#/tmp/art-spm#R#g' /tmp/art-spm/.build/workspace-state.json) <(sed 's#/tmp/art-swx#R#g' /tmp/art-swx/.build/workspace-state.json)
(cd /tmp/art-swx2 && time "$swx" package resolve)
echo "artifacts identical"

# Build/run through SwiftPM, a script with inline dependencies, and a tool.
(cd /tmp/swx && "$swx" run App)
(cd "$work" && "$swx" run greet.swift Linux)
"$swx" tool run --executable math apple/swift-argument-parser@1.5.0 add 2 3
