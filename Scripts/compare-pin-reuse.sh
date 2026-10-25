#!/usr/bin/env bash
# Differential check of lockfile reuse (SwiftPM's resolution precomputation) on a
# tools-5.9 package, whose Package.resolved has no originHash:
#   1. pins that still fit are reused without listing any tags,
#   2. a new dependency and 3. a requirement above the pin trigger a real resolve.
# Every step must leave Package.resolved and workspace-state.json identical to SwiftPM's.
#
#   Scripts/compare-pin-reuse.sh [swx-binary]
set -euo pipefail

swx_input="${1:-$(swift build -c release --show-bin-path)/swx}"
readonly swx="$(cd "$(dirname "$swx_input")" && pwd)/$(basename "$swx_input")"
readonly work="$(mktemp -d)"
readonly argument_parser='.package(url: "https://github.com/apple/swift-argument-parser"'
readonly collections='.package(url: "https://github.com/apple/swift-collections", from: "1.0.0")'
readonly products='.product(name: "ArgumentParser", package: "swift-argument-parser"), .product(name: "Collections", package: "swift-collections")'
trap 'rm -rf "$work"' EXIT

write_package() {
    mkdir -p "$1/Sources/App"
    echo 'print(1)' > "$1/Sources/App/main.swift"
    cat > "$1/Package.swift" <<EOF
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "App",
    dependencies: [$2],
    targets: [.executableTarget(name: "App", dependencies: [$3])]
)
EOF
}

# Resolve with both tools, then compare; prints how many repositories listed tags.
step() {
    local title="$1" dependencies="$2" target_dependencies="$3"
    for tool in spm swx; do
        write_package "$work/$tool" "$dependencies" "$target_dependencies"
    done
    (cd "$work/spm" && swift package resolve >/dev/null 2>&1)
    local listings
    listings=$(cd "$work/swx" && SWX_TRACE=1 "$swx" package resolve 2>&1 | grep -c "spawn git ls-remote" || true)
    diff "$work/spm/Package.resolved" "$work/swx/Package.resolved"
    diff <(sed "s#$work/spm#R#g" "$work/spm/.build/workspace-state.json") <(sed "s#$work/swx#R#g" "$work/swx/.build/workspace-state.json")
    echo "$title: identical, $listings tag listings"
}

step "pinned at 1.3.0" "$argument_parser, exact: \"1.3.0\")" '.product(name: "ArgumentParser", package: "swift-argument-parser")'
step "loosened, pin fits" "$argument_parser, from: \"1.2.0\")" '.product(name: "ArgumentParser", package: "swift-argument-parser")'
step "new dependency" "$argument_parser, from: \"1.2.0\"), $collections" "$products"
step "requirement above pin" "$argument_parser, from: \"1.5.0\"), $collections" "$products"
