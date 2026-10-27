#!/usr/bin/env bash
# End-to-end check of `swx add`, `swx remove` and `swx upgrade` on a copy of the sample package:
# each edit leaves the manifest it should, and the resolve after it writes the Package.resolved
# SwiftPM writes for that manifest. `add` by name needs the Swift Package Index and GitHub's API
# (set GITHUB_TOKEN to avoid its rate limit).
#
#   Scripts/check-manifest-edits.sh [swx-binary]
set -euo pipefail

readonly repo="$(cd "$(dirname "$0")/.." && pwd)"
swx_input="${1:-$(swift build -c release --show-bin-path)/swx}"
readonly swx="$(cd "$(dirname "$swx_input")" && pwd)/$(basename "$swx_input")"
readonly work="$(cd "$(mktemp -d)" && pwd -P)"
readonly package="$work/package"
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT

fail() {
    echo "$*"
    exit 1
}

# Keeps the lockfile from before an edit, for SwiftPM to start from.
before_edit() {
    cp "$package/Package.resolved" "$work/prior.resolved"
}

# SwiftPM resolves a copy of the edited package from the lockfile before the edit; its
# Package.resolved must match swx's.
same_as_swiftpm() {
    local step="$1"
    rm -rf "$work/swiftpm"
    rsync -a --exclude .build "$package/" "$work/swiftpm/"
    cp "$work/prior.resolved" "$work/swiftpm/Package.resolved"
    (cd "$work/swiftpm" && swift package resolve >/dev/null 2>&1) || fail "$step: SwiftPM can't resolve the edited manifest"
    cmp -s "$package/Package.resolved" "$work/swiftpm/Package.resolved" || {
        diff "$work/swiftpm/Package.resolved" "$package/Package.resolved" | head -8
        fail "$step: Package.resolved differs from SwiftPM's"
    }
    echo "$step: resolves like SwiftPM"
}

# Versions vary with new releases; compare manifests with every version literal blanked.
without_versions() {
    sed -E 's/(from|exact): "[^"]*"/\1: "*"/g' "$1"
}

mkdir -p "$package/Sources/App"
cp "$repo/Tests/Fixtures/sample/Package.swift" "$package/"
echo 'print("hi")' > "$package/Sources/App/main.swift"
cd "$package"
"$swx" package resolve -q

# remove: the dependency and its product go, nothing else.
before_edit
"$swx" remove swift-nio >/dev/null
! grep -q swift-nio Package.swift || fail "remove: swift-nio is still in the manifest"
[ "$(grep -c '' Package.swift)" = "$(( $(grep -c '' "$repo/Tests/Fixtures/sample/Package.swift") - 2 ))" ] || fail "remove: more than two lines changed"
same_as_swiftpm remove

# add by name: the Swift Package Index finds apple/swift-nio; the manifest is the original again.
before_edit
"$swx" add swift-nio --product NIOCore >/dev/null
diff <(without_versions "$repo/Tests/Fixtures/sample/Package.swift") <(without_versions Package.swift) || fail "add: the manifest isn't the original"
same_as_swiftpm "add by name"

# add owner/repo@version with its default library.
before_edit
"$swx" add apple/swift-collections@1.1.0 >/dev/null
grep -q '"https://github.com/apple/swift-collections.git", from: "1.1.0"\|"https://github.com/apple/swift-collections", from: "1.1.0"' Package.swift || fail "add: no swift-collections from 1.1.0"
grep -q '.product(name: "Collections", package: "swift-collections")' Package.swift || fail "add: App doesn't use Collections"
same_as_swiftpm "add owner/repo@version"

# upgrade: a requirement that excludes the newest release moves to it; --dry-run edits nothing.
sed -i.bak 's|swift-argument-parser", from: "[^"]*"|swift-argument-parser", from: "0.4.0"|' Package.swift && rm Package.swift.bak
"$swx" package resolve -q
cp Package.swift "$work/before.swift"
before_edit
"$swx" upgrade --dry-run | grep -q "swift-argument-parser: would move 0.4.0 → " || fail "upgrade --dry-run: no move planned"
cmp -s Package.swift "$work/before.swift" || fail "upgrade --dry-run edited the manifest"
"$swx" upgrade swift-argument-parser >/dev/null
! grep -q 'from: "0.4.0"' Package.swift || fail "upgrade: the requirement didn't move"
[ "$(diff "$work/before.swift" Package.swift | grep -c '^>')" = "1" ] || fail "upgrade: more than one line changed"
same_as_swiftpm upgrade

# The edited package builds.
swift build >/dev/null || fail "the edited package doesn't build"
echo "edits: the edited package builds"
