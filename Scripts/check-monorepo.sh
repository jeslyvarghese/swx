#!/usr/bin/env bash
# End-to-end check of `--all` on a monorepo: a root package and two local packages
# (Packages/Core, and Packages/Tool depending on Core and on swift-argument-parser).
# - `swx package resolve --all` writes, for every package, the Package.resolved and
#   workspace-state.json SwiftPM writes for it;
# - `swx package resolve --check --all` passes, then fails for a stale lockfile, naming it;
# - `swx build --all` builds every package; `swx test --all --selective` runs every test
#   target once and nothing the second time;
# - `swx cache push --all`, then `pull --all` into an empty store, lets every package resolve
#   without git.
#
#   Scripts/check-monorepo.sh [swx-binary]
set -euo pipefail

swx_input="${1:-$(swift build -c release --show-bin-path)/swx}"
readonly swx="$(cd "$(dirname "$swx_input")" && pwd)/$(basename "$swx_input")"
readonly work="$(cd "$(mktemp -d)" && pwd -P)"
trap 'status=$?; chmod -R u+w "$work"; rm -rf "$work"; exit $status' EXIT
export SWX_CACHE_DIR="$work/store"

fail() {
    echo "check-monorepo: $*" >&2
    exit 1
}

# A package directory with one library (and its tests, when asked).
make_package() {
    local directory="$1" manifest="$2" name="$3" function="$4"
    mkdir -p "$directory/Sources/$name" "$directory/Tests/${name}Tests"
    printf '%s\n' "$manifest" > "$directory/Package.swift"
    echo "public func $function() -> Int { 1 }" > "$directory/Sources/$name/$name.swift"
    printf 'import Testing\n@testable import %s\n@Test func works() { #expect(%s() == 1) }\n' "$name" "$function" > "$directory/Tests/${name}Tests/${name}Tests.swift"
}

readonly repo="$work/repo"
make_package "$repo/Packages/Core" '// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Core", products: [.library(name: "Core", targets: ["Core"])],
  targets: [.target(name: "Core"), .testTarget(name: "CoreTests", dependencies: ["Core"])])' Core core
make_package "$repo/Packages/Tool" '// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Tool", products: [.library(name: "Tool", targets: ["Tool"])],
  dependencies: [.package(path: "../Core"), .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")],
  targets: [.target(name: "Tool", dependencies: ["Core", .product(name: "ArgumentParser", package: "swift-argument-parser")]),
    .testTarget(name: "ToolTests", dependencies: ["Tool"])])' Tool tool
make_package "$repo" '// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Root", dependencies: [.package(path: "Packages/Tool")],
  targets: [.target(name: "Root", dependencies: [.product(name: "Tool", package: "Tool")]),
    .testTarget(name: "RootTests", dependencies: ["Root"])])' Root root
readonly packages=(. Packages/Core Packages/Tool)

# MARK: Resolve every package, as SwiftPM would one by one

cp -R "$repo" "$work/spm"
for package in "${packages[@]}"; do
    (cd "$work/spm/$package" && swift package resolve --cache-path "$work/spm-cache" >/dev/null 2>&1) || fail "SwiftPM could not resolve $package"
done
"$swx" package resolve --all --package-path "$repo" > "$work/resolve.out"
grep -q "3 of 3 packages succeeded" "$work/resolve.out" || fail "resolve --all: $(cat "$work/resolve.out")"
for package in "${packages[@]}"; do
    if [ -f "$work/spm/$package/Package.resolved" ]; then
        cmp -s "$work/spm/$package/Package.resolved" "$repo/$package/Package.resolved" || fail "$package: Package.resolved differs from SwiftPM's"
    else
        [ ! -f "$repo/$package/Package.resolved" ] || fail "$package: swx wrote a Package.resolved SwiftPM doesn't"
    fi
    diff -q <(sed "s#$work/spm#ROOT#g" "$work/spm/$package/.build/workspace-state.json") <(sed "s#$repo#ROOT#g" "$repo/$package/.build/workspace-state.json") >/dev/null \
        || { diff <(sed "s#$work/spm#ROOT#g" "$work/spm/$package/.build/workspace-state.json") <(sed "s#$repo#ROOT#g" "$repo/$package/.build/workspace-state.json") | head -30; fail "$package: workspace-state.json differs from SwiftPM's"; }
done
echo "resolve --all writes what SwiftPM writes for each package"

# MARK: Lockfile checks

"$swx" package resolve --check --all --package-path "$repo" >/dev/null || fail "check --all failed on fresh lockfiles"
# A requirement the pinned argument-parser no longer meets makes Tool's lockfile stale.
cp "$repo/Packages/Tool/Package.swift" "$work/Tool.manifest"
sed -i.bak 's/from: "1.5.0"/.upToNextMinor(from: "1.5.0")/' "$repo/Packages/Tool/Package.swift"
if "$swx" package resolve --check --all --package-path "$repo" > "$work/check.out" 2> "$work/check.err"; then
    fail "check --all passed with a stale lockfile"
fi
grep -q "^Packages/Tool: error: Package.resolved is out of date" "$work/check.err" || fail "check --all didn't name the stale package: $(cat "$work/check.err")"
cp "$work/Tool.manifest" "$repo/Packages/Tool/Package.swift"
rm "$repo/Packages/Tool/Package.swift.bak"
echo "resolve --check --all names the stale lockfile"

# MARK: Builds and tests

"$swx" build --all --package-path "$repo" > "$work/build.out" 2>&1 || fail "build --all failed: $(tail -20 "$work/build.out")"
grep -q "3 of 3 packages succeeded" "$work/build.out" || fail "build --all: $(tail -5 "$work/build.out")"
"$swx" test --all --selective --package-path "$repo" > "$work/test1.out" 2>&1 || fail "test --all failed: $(tail -20 "$work/test1.out")"
"$swx" test --all --selective --package-path "$repo" > "$work/test2.out" 2>&1 || fail "the second test --all failed"
[ "$(grep -c "unchanged since they passed; nothing to run" "$work/test2.out")" = "3" ] || fail "the second test --all --selective ran tests again: $(cat "$work/test2.out")"
echo "build --all and test --all --selective cover every package"

# MARK: The remote cache, for every package

"$swx" cache push --all --remote "$work/remote" --package-path "$repo" >/dev/null || fail "cache push --all failed"
export SWX_CACHE_DIR="$work/empty-store"
for package in "${packages[@]}"; do
    rm -rf "$repo/$package/.build"
done
"$swx" cache pull --all --remote "$work/remote" --package-path "$repo" >/dev/null || fail "cache pull --all failed"
spawns="$(SWX_TRACE=1 "$swx" package resolve --all --package-path "$repo" 2>&1 | grep -c 'spawn git' || true)"
[ "$spawns" = "0" ] || fail "resolve --all after pull --all ran git $spawns times"
echo "cache push --all and pull --all restore every package without git"
