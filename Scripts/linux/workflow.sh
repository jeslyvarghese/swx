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

# Build/run through SwiftPM, a script with inline dependencies, and a tool.
(cd /tmp/swx && "$swx" run App)
(cd "$work" && "$swx" run greet.swift Linux)
"$swx" tool run --executable math apple/swift-argument-parser@1.5.0 add 2 3
