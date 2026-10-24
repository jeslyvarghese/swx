#!/usr/bin/env bash
# Resolves every package in Corpus/packages.txt (each as the sole dependency of a scratch
# root) into one shared cache, growing the manifest corpus used by `swx debug manifest-parity`.
#
#   Scripts/build-corpus.sh <cache-dir> [swx-binary]
set -uo pipefail

readonly cache="$1"
swx_input="${2:-$(swift build -c release --show-bin-path)/swx}"
readonly swx="$(cd "$(dirname "$swx_input")" && pwd)/$(basename "$swx_input")"
readonly list="$(cd "$(dirname "$0")/.." && pwd)/Corpus/packages.txt"
readonly work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
grep -v '^#' "$list" | while read -r url; do
    [ -z "$url" ] && continue
    name="$(basename "$url" .git)"
    root="$work/$name-root"
    mkdir -p "$root/Sources/Root"
    echo 'let x = 0' > "$root/Sources/Root/x.swift"

    # Any version: we want the newest release of each package.
    cat > "$root/Package.swift" <<MANIFEST
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Root",
    dependencies: [.package(url: "$url", "0.0.1"..<"999.0.0")],
    targets: [.target(name: "Root")]
)
MANIFEST

    if output=$(cd "$root" && "$swx" package resolve --cache-path "$cache" 2>&1); then
        echo "ok    $name: $(echo "$output" | tail -1)"
    else
        echo "FAIL  $name: $(echo "$output" | tail -3)"
        failures=$((failures + 1))
    fi
done
