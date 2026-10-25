#!/usr/bin/env bash
# Differential check for package registries (SE-0292) against SwiftPM.
#
# Serves fixture packages with Scripts/test-registry.py:
#   mona.LinkedList  1.0.0, 1.1.0 (1.1.0 also has Package@swift-5.8/6.0.swift, and full metadata)
#   mona.Graph       1.0.0 -> mona.LinkedList (registry) + swift-argument-parser (git)
# then resolves an app depending on mona.Graph with SwiftPM and with swx, each with its own
# --config-path / --security-path, and compares Package.resolved, workspace-state.json, the
# download trees (with .registry-metadata) and the registry fingerprints. Repeats behind
# HTTP basic auth with credentials from a netrc file, then the source-control-to-registry
# transformations (--use-registry-identity-for-scm and --replace-scm-with-registry), with the
# registry mapping swift-argument-parser's URL to a fixture `apple.swift-argument-parser`.
#
#   Scripts/compare-registry.sh [swx-binary]
set -euo pipefail

swx_input="${1:-$(swift build -c release --show-bin-path)/swx}"
readonly swx="$(cd "$(dirname "$swx_input")" && pwd)/$(basename "$swx_input")"
readonly root="$(cd "$(dirname "$0")/.." && pwd)"
readonly work="$(cd "$(mktemp -d)" && pwd -P)"
server=""
trap '[ -n "$server" ] && kill "$server" 2>/dev/null; rm -rf "$work"' EXIT

# MARK: Fixtures

package() {
    local scope="$1" name="$2" version="$3" manifest="$4"
    local directory="$work/packages/$scope/$name/$version"
    mkdir -p "$directory/Sources/$name"
    printf '%s\n' "$manifest" > "$directory/Package.swift"
    echo "public let version = \"$version\"" > "$directory/Sources/$name/$name.swift"
}

readonly linked_list='// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "LinkedList", products: [.library(name: "LinkedList", targets: ["LinkedList"])], targets: [.target(name: "LinkedList")])'
package mona LinkedList 1.0.0 "$linked_list"
package mona LinkedList 1.1.0 "$linked_list"
printf '%s\n' "${linked_list/5.9/5.8}" > "$work/packages/mona/LinkedList/1.1.0/Package@swift-5.8.swift"
# A newer version-specific manifest that a 6.x toolchain prefers (fetched with ?swift-version=).
printf '%s\n' "${linked_list/5.9/6.0}" > "$work/packages/mona/LinkedList/1.1.0/Package@swift-6.0.swift"
cat > "$work/packages/mona/LinkedList/1.1.0.metadata.json" <<'EOF'
{
  "author": {"name": "Mona", "email": "mona@example.com", "organization": {"name": "Example", "url": "https://example.com"}},
  "description": "A linked list",
  "licenseURL": "https://example.com/LICENSE",
  "readmeURL": "https://example.com/README",
  "repositoryURLs": ["https://github.com/mona/LinkedList", "git@github.com:mona/LinkedList.git"]
}
EOF
package mona Graph 1.0.0 '// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Graph",
    products: [.library(name: "Graph", targets: ["Graph"])],
    dependencies: [
        .package(id: "mona.LinkedList", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [.target(name: "Graph", dependencies: [
        .product(name: "LinkedList", package: "mona.LinkedList"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
    ])]
)'

# MARK: Helpers

start_registry() {
    [ -n "$server" ] && kill "$server" 2>/dev/null && wait "$server" 2>/dev/null || true
    python3 -I "$root/Scripts/test-registry.py" --root "$work/packages" "$@" > "$work/port" &
    server=$!
    for _ in $(seq 50); do [ -s "$work/port" ] && break; sleep 0.1; done
    port="$(cat "$work/port")"
}

# A fresh app per tool, pointed at the registry.
make_app() {
    local directory="$work/$1"
    rm -rf "$directory" "$work/$1-security" "$work/$1-config" "$work/$1-cache"
    mkdir -p "$directory/Sources/App" "$work/$1-config"
    cat > "$directory/Package.swift" <<'EOF'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "App",
    dependencies: [.package(id: "mona.Graph", from: "1.0.0")],
    targets: [.executableTarget(name: "App", dependencies: [.product(name: "Graph", package: "mona.Graph")])]
)
EOF
    echo 'import Graph; print(version)' > "$directory/Sources/App/main.swift"
    (cd "$directory" && swift package-registry set --allow-insecure-http "http://127.0.0.1:$port" >/dev/null)
}

shared_flags() {
    echo "--config-path $work/$1-config --security-path $work/$1-security --cache-path $work/$1-cache"
}

tree_signature() {
    (cd "$1" && find . -type f | sort | while read -r file; do echo "$file $(shasum -a 256 < "$file" | cut -d' ' -f1)"; done)
}

compare() {
    diff "$work/spm/Package.resolved" "$work/swx/Package.resolved"
    diff <(sed "s#$work/spm#R#g" "$work/spm/.build/workspace-state.json") <(sed "s#$work/swx#R#g" "$work/swx/.build/workspace-state.json")
    diff <(tree_signature "$work/spm/.build/registry/downloads") <(tree_signature "$work/swx/.build/registry/downloads")
    for fingerprints in "$work"/spm-security/fingerprints/mona.*.json; do
        diff "$fingerprints" "$work/swx-security/fingerprints/$(basename "$fingerprints")"
    done
}

# MARK: Open registry

start_registry
make_app spm
make_app swx
# shellcheck disable=SC2046
(cd "$work/spm" && swift package resolve $(shared_flags spm) >/dev/null 2>&1)
# shellcheck disable=SC2046
(cd "$work/swx" && "$swx" package resolve $(shared_flags swx) >/dev/null)
compare
echo "registry: Package.resolved, state, downloads and fingerprints identical"

# A clean .build restores from the lockfile; swift build accepts the result.
rm -rf "$work/swx/.build"
# shellcheck disable=SC2046
(cd "$work/swx" && "$swx" package resolve $(shared_flags swx) >/dev/null && swift build --disable-automatic-resolution $(shared_flags swx) >/dev/null 2>&1 && .build/debug/App)
echo "restored from Package.resolved; swift build accepts swx downloads"

# MARK: Basic auth with netrc credentials (on macOS, SwiftPM 6.4 reads netrc only with --netrc)

start_registry --basic "mona:secret"
cat > "$work/netrc" <<EOF
machine 127.0.0.1 login mona password secret
EOF
# What `swift package-registry login` records: the host uses basic auth.
for tool in spm swx; do
    make_app "$tool"
    cat > "$work/$tool/.swiftpm/configuration/registries.json" <<EOF
{
  "authentication" : {
    "127.0.0.1:$port" : {
      "type" : "basic"
    }
  },
  "registries" : {
    "[default]" : {
      "supportsAvailability" : false,
      "url" : "http://127.0.0.1:$port"
    }
  },
  "version" : 1
}
EOF
done
# shellcheck disable=SC2046
(cd "$work/spm" && swift package resolve $(shared_flags spm) --netrc --netrc-file "$work/netrc" >/dev/null)
# shellcheck disable=SC2046
(cd "$work/swx" && "$swx" package resolve $(shared_flags swx) --netrc --netrc-file "$work/netrc" >/dev/null)
compare
echo "basic auth via netrc: identical"

# MARK: Source control to registry

# A registry stand-in for swift-argument-parser, and the URL mapping /identifiers answers with.
mkdir -p "$work/packages/apple/swift-argument-parser/1.5.0/Sources/ArgumentParser"
cat > "$work/packages/apple/swift-argument-parser/1.5.0/Package.swift" <<'EOF'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "swift-argument-parser", products: [.library(name: "ArgumentParser", targets: ["ArgumentParser"])], targets: [.target(name: "ArgumentParser")])
EOF
echo 'public struct ParsableArguments {}' > "$work/packages/apple/swift-argument-parser/1.5.0/Sources/ArgumentParser/ArgumentParser.swift"
echo '{"https://github.com/apple/swift-argument-parser": "apple.swift-argument-parser"}' > "$work/scm-map.json"
start_registry --scm-map "$work/scm-map.json"

make_scm_app() {
    make_app "$1"
    cat > "$work/$1/Package.swift" <<'EOF'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "App",
    dependencies: [.package(url: "https://github.com/apple/swift-argument-parser", exact: "1.5.0")],
    targets: [.executableTarget(name: "App", dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser")])]
)
EOF
    echo 'import ArgumentParser' > "$work/$1/Sources/App/main.swift"
}

compare_lockfiles() {
    diff "$work/spm/Package.resolved" "$work/swx/Package.resolved"
    diff <(sed "s#$work/spm#R#g" "$work/spm/.build/workspace-state.json") <(sed "s#$work/swx#R#g" "$work/swx/.build/workspace-state.json")
}

for flag in --use-registry-identity-for-scm --replace-scm-with-registry; do
    make_scm_app spm
    make_scm_app swx
    # shellcheck disable=SC2046
    (cd "$work/spm" && swift package resolve $(shared_flags spm) "$flag" >/dev/null 2>&1)
    # shellcheck disable=SC2046
    (cd "$work/swx" && "$swx" package resolve $(shared_flags swx) "$flag" >/dev/null)
    compare_lockfiles
    echo "$flag: Package.resolved and state identical ($(grep -o '"identity" : "[^"]*"' "$work/swx/Package.resolved" | head -1))"
done
