#!/usr/bin/env bash
# Differential check: `swx package resolve --check` must say "stale" exactly when
# `swift package resolve` would change Package.resolved, for lockfiles with and without an
# origin hash (v3 and v2).
#
#   Scripts/compare-lock-check.sh [swx-binary]
set -euo pipefail

swx_input="${1:-$(swift build -c release --show-bin-path)/swx}"
readonly swx="$(cd "$(dirname "$swx_input")" && pwd)/$(basename "$swx_input")"
readonly work="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$work"' EXIT

readonly parser='.package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")'
readonly collections='.package(url: "https://github.com/apple/swift-collections", from: "1.1.0")'
status=0

# A package at `tools` with `dependencies`, resolved by swx.
make_package() {
    local directory="$1" tools="$2" dependencies="$3"
    mkdir -p "$directory/Sources/App"
    echo 'print("hi")' > "$directory/Sources/App/main.swift"
    printf '// swift-tools-version: %s\nimport PackageDescription\nlet package = Package(name: "App", dependencies: [%s], targets: [.executableTarget(name: "App")])\n' \
        "$tools" "$dependencies" > "$directory/Package.swift"
    (cd "$directory" && "$swx" package resolve -q)
}

# Apply `edit` to the manifest, then ask both tools: swx's verdict vs whether SwiftPM rewrites the file.
scenario() {
    local name="$1" tools="$2" edit="$3"
    local directory="$work/$name"
    make_package "$directory" "$tools" "$parser"
    (cd "$directory" && eval "$edit")

    local swx_says=fresh
    (cd "$directory" && "$swx" package resolve --check >/dev/null 2>&1) || swx_says=stale

    # SwiftPM resolves a copy; a lockfile it rewrites, or can't resolve at all, was stale.
    rsync -a "$directory/" "$directory-spm/"
    local swiftpm_says=fresh
    if (cd "$directory-spm" && swift package resolve >/dev/null 2>&1); then
        cmp -s "$directory/Package.resolved" "$directory-spm/Package.resolved" || swiftpm_says=stale
    else
        swiftpm_says=stale
    fi

    if [ "$swx_says" = "$swiftpm_says" ]; then
        printf '%-38s %-6s agrees with swiftpm' "$name" "$swx_says"
    else
        printf '%-38s swx %s, swiftpm %s  DIFFERS' "$name" "$swx_says" "$swiftpm_says"
        status=1
    fi

    # A real resolve must then leave the same Package.resolved as SwiftPM's.
    if [ -s "$directory-spm/Package.resolved" ] && (cd "$directory" && "$swx" package resolve -q >/dev/null 2>&1); then
        if cmp -s "$directory/Package.resolved" "$directory-spm/Package.resolved"; then
            echo ", resolves identically"
        else
            echo ", resolved file DIFFERS"
            diff "$directory-spm/Package.resolved" "$directory/Package.resolved" | head -6 || true
            status=1
        fi
    else
        echo
    fi
}

readonly comment="echo '// a comment' >> Package.swift"
readonly add_dependency="sed -i.bak 's#$parser#$parser, $collections#' Package.swift"
readonly raise_requirement="sed -i.bak 's#from: \"1.3.0\"#from: \"99.0.0\"#' Package.swift"
readonly loosen_requirement="sed -i.bak 's#from: \"1.3.0\"#from: \"1.0.0\"#' Package.swift"

for tools in 6.0 5.9; do
    scenario "tools $tools, untouched" "$tools" "true"
    scenario "tools $tools, comment added" "$tools" "$comment"
    scenario "tools $tools, dependency added" "$tools" "$add_dependency"
    scenario "tools $tools, requirement above pin" "$tools" "$raise_requirement"
    scenario "tools $tools, requirement loosened" "$tools" "$loosen_requirement"
done

exit $status
