#!/usr/bin/env bash
# Differential check for git submodules inside dependencies.
#
# Builds local repositories served over file://:
#   leaf  - two commits
#   mid   - submodule vendor/leaf, pinned to leaf's first (untagged) commit
#   pkg   - a Swift package (tag 1.0.0) with submodule External/mid (with its nested
#           submodule) and a second submodule marked `update = none`
# then resolves an app that depends on pkg with SwiftPM and with swx and compares the
# checkout trees (ignoring .git), Package.resolved and workspace-state.json.
#
# URLs are absolute: SwiftPM resolves relative submodule URLs against its local repository
# cache, where they don't exist (swx resolves them against the package URL, like git).
#
#   Scripts/compare-submodules.sh [swx-binary]
set -euo pipefail

swx_input="${1:-$(swift build -c release --show-bin-path)/swx}"
readonly swx="$(cd "$(dirname "$swx_input")" && pwd)/$(basename "$swx_input")"
readonly work="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$work"' EXIT

# git refuses file:// submodules by default; SwiftPM runs plain `git submodule update`.
export GIT_CONFIG_COUNT=3
export GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
export GIT_CONFIG_KEY_1=user.email GIT_CONFIG_VALUE_1=fixture@example.com
export GIT_CONFIG_KEY_2=user.name GIT_CONFIG_VALUE_2=fixture

readonly repos="$work/repos"
readonly sources="$work/sources"
mkdir -p "$repos" "$sources"

new_repository() {
    git init --quiet --initial-branch=main "$sources/$1"
}

publish() {
    git clone --quiet --bare "$sources/$1" "$repos/$1.git"
}

add_submodule() {
    local repository="$1" name="$2" path="$3"
    git -C "$sources/$repository" submodule --quiet add "file://$repos/$name.git" "$path"
}

# leaf: two commits.
new_repository leaf
echo "leaf v1" > "$sources/leaf/leaf.txt"
git -C "$sources/leaf" add . && git -C "$sources/leaf" commit --quiet -m "leaf 1"
echo "leaf v2" > "$sources/leaf/leaf.txt"
git -C "$sources/leaf" commit --quiet -am "leaf 2"
publish leaf

# mid: nested submodule pinned to leaf's first commit.
new_repository mid
echo "mid" > "$sources/mid/mid.txt"
git -C "$sources/mid" add . && git -C "$sources/mid" commit --quiet -m "mid"
add_submodule mid leaf vendor/leaf
git -C "$sources/mid/vendor/leaf" checkout --quiet HEAD~1
git -C "$sources/mid" add . && git -C "$sources/mid" commit --quiet -m "add leaf"
publish mid

# pkg: the Swift package, with a recursive submodule and one opted out of updates.
new_repository pkg
mkdir -p "$sources/pkg/Sources/Kit"
cat > "$sources/pkg/Package.swift" <<'EOF'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Kit", products: [.library(name: "Kit", targets: ["Kit"])], targets: [.target(name: "Kit")])
EOF
echo 'public let kit = 1' > "$sources/pkg/Sources/Kit/Kit.swift"
git -C "$sources/pkg" add . && git -C "$sources/pkg" commit --quiet -m "kit"
add_submodule pkg mid External/mid
add_submodule pkg leaf External/skipped
git -C "$sources/pkg" config --file .gitmodules submodule.External/skipped.update none
git -C "$sources/pkg" add . && git -C "$sources/pkg" commit --quiet -m "submodules"
git -C "$sources/pkg" tag 1.0.0
publish pkg

# The same app for both tools.
for tool in spm swx; do
    mkdir -p "$work/$tool/Sources/App"
    cat > "$work/$tool/Package.swift" <<EOF
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "App",
    dependencies: [.package(url: "file://$repos/pkg.git", from: "1.0.0")],
    targets: [.executableTarget(name: "App", dependencies: [.product(name: "Kit", package: "pkg")])]
)
EOF
    echo 'import Kit; print(kit)' > "$work/$tool/Sources/App/main.swift"
done

(cd "$work/spm" && swift package resolve >/dev/null)
(cd "$work/swx" && "$swx" package resolve --cache-path "$work/cache" >/dev/null)

# File contents and layout, without git metadata.
tree_signature() {
    (cd "$1" && find . -name .git -prune -o -type f -print | sort | while read -r file; do
        echo "$file $(shasum -a 256 < "$file" | cut -d' ' -f1)"
    done; find . -name .git -prune -o -type d -print | sort)
}

diff <(tree_signature "$work/spm/.build/checkouts/pkg") <(tree_signature "$work/swx/.build/checkouts/pkg")
echo "checkout trees identical:"
tree_signature "$work/swx/.build/checkouts/pkg" | grep -E "txt|Kit.swift" | sed 's/^/  /'

diff "$work/spm/Package.resolved" "$work/swx/Package.resolved"
diff <(sed "s#$work/spm#R#g" "$work/spm/.build/workspace-state.json") <(sed "s#$work/swx#R#g" "$work/swx/.build/workspace-state.json")
echo "Package.resolved and workspace-state.json identical"

(cd "$work/swx" && swift build --disable-automatic-resolution >/dev/null && echo "swift build accepts swx checkouts")
