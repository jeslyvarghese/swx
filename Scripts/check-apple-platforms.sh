#!/usr/bin/env bash
# Builds and tests a package with a dependency on every Apple simulator platform that has a
# runtime installed (`swx test --platform <p>`), plus a generic device build for each.
#
#   Scripts/check-apple-platforms.sh [swx-binary] [platform …]   (default: ios watchos tvos visionos)
set -euo pipefail

swx_input="${1:-$(swift build -c release --show-bin-path)/swx}"
readonly swx="$(cd "$(dirname "$swx_input")" && pwd)/$(basename "$swx_input")"
shift || true
platforms=("$@")
[ ${#platforms[@]} -eq 0 ] && platforms=(ios watchos tvos visionos)
readonly work="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/Kit/Sources/Kit" "$work/Kit/Tests/KitTests"
cd "$work/Kit"
cat > Package.swift <<'EOF'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Kit",
    platforms: [.iOS(.v17), .watchOS(.v10), .tvOS(.v17), .visionOS(.v1)],
    products: [.library(name: "Kit", targets: ["Kit"])],
    dependencies: [.package(url: "https://github.com/apple/swift-collections", from: "1.1.0")],
    targets: [
        .target(name: "Kit", dependencies: [.product(name: "OrderedCollections", package: "swift-collections")]),
        .testTarget(name: "KitTests", dependencies: ["Kit"]),
    ]
)
EOF
printf 'import OrderedCollections\npublic func unique(_ values: [Int]) -> [Int] { Array(OrderedSet(values)) }\n' > Sources/Kit/Kit.swift
printf 'import Testing\nimport Kit\n@Test func keepsFirstOccurrences() { #expect(unique([3, 1, 3, 2, 1]) == [3, 1, 2]) }\n' > Tests/KitTests/KitTests.swift

# simctl's runtime names per platform.
runtime_name() {
    case "$1" in
        ios) echo "iOS" ;;
        watchos) echo "watchOS" ;;
        tvos) echo "tvOS" ;;
        visionos) echo "visionOS" ;;
    esac
}

# Prints the end of the failing step's log, which would otherwise vanish with $work.
readonly log_lines=80
fail() {
    echo "$1: $2 failed; last $log_lines lines of its log:" >&2
    tail -n "$log_lines" "$work/$1-$2.log" >&2
    exit 1
}

for platform in "${platforms[@]}"; do
    if ! xcrun simctl list runtimes | grep -q "^$(runtime_name "$platform") "; then
        echo "$platform: skipped (no simulator runtime installed)"
        continue
    fi
    "$swx" build --platform "$platform" --destination device > "$work/$platform-build.log" 2>&1 \
        || fail "$platform" build
    "$swx" test --platform "$platform" > "$work/$platform-test.log" 2>&1 \
        || fail "$platform" test
    grep -q "TEST SUCCEEDED" "$work/$platform-test.log" || fail "$platform" test
    echo "$platform: device build and simulator tests succeeded"
done
