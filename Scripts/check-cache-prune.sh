#!/usr/bin/env bash
# End-to-end check of `swx cache size|prune` and `swx self update`:
# - a resolved project's trees and repositories survive a prune of everything unused, the
#   project still builds offline from its checkouts, and once its Package.resolved is gone the
#   same prune removes them;
# - scratch directories don't pile up after a push and a pull;
# - a directory remote is pruned of files swx wrote, and leaves other files alone;
# - a copy of the binary updates itself to a published release (when --self-update is given).
#
#   Scripts/check-cache-prune.sh [swx-binary] [--self-update]
set -euo pipefail

readonly repo="$(cd "$(dirname "$0")/.." && pwd)"
swx_input="${1:-$(swift build -c release --show-bin-path)/swx}"
readonly swx="$(cd "$(dirname "$swx_input")" && pwd)/$(basename "$swx_input")"
readonly self_update="${2:-}"
readonly work="$(cd "$(mktemp -d)" && pwd -P)"
# A release that has `swx self update` would let it update again; v0.4.0 only proves the install.
readonly update_tag="v0.4.0"
trap 'status=$?; chmod -R u+w "$work"; rm -rf "$work"; exit $status' EXIT
export SWX_CACHE_DIR="$work/store"

fail() {
    echo "check-cache-prune: $*" >&2
    exit 1
}

entries() {
    # The entry count of one section in `swx cache size` ("  source trees   5 entries  8.2 MB").
    "$swx" cache size | awk -v name="$1" 'index($0, "  " name " ") == 1 { for (i = 1; i <= NF; i++) if ($i == "entries") print $(i - 1) }'
}

# A resolved sample package.
mkdir -p "$work/package/Sources/App"
cp "$repo/Tests/Fixtures/sample/Package.swift" "$work/package/"
echo 'print("hi")' > "$work/package/Sources/App/main.swift"
(cd "$work/package" && "$swx" package resolve -q)
trees="$(entries "source trees")"
[ -n "$trees" ] && [ "$trees" -gt 0 ] || fail "no source trees after resolving"

# Pinned entries stay even when everything unused goes.
"$swx" cache prune --older-than 0h >/dev/null
[ "$(entries "source trees")" = "$trees" ] || fail "a prune removed trees the project pins"
[ -n "$(entries "git repositories")" ] || fail "a prune removed repositories the project pins"
echo "pinned trees and repositories survive a prune"

# A push and a pull leave no scratch behind.
remote="$work/remote"
(cd "$work/package" && "$swx" cache push --remote "$remote" >/dev/null)
(cd "$work/package" && SWX_CACHE_DIR="$work/other-store" "$swx" cache pull --remote "$remote" >/dev/null)
for store in "$work/store" "$work/other-store"; do
    leftovers="$(find "$store/tmp" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
    [ "$leftovers" = "0" ] || fail "$leftovers scratch directories left in $store"
done
echo "push and pull leave no scratch"

# Once the project's lockfile is gone, nothing protects its entries; the checkouts are copies.
mv "$work/package/Package.resolved" "$work/Package.resolved.saved"
dry="$("$swx" cache prune --older-than 0h --dry-run | tail -1)"
[[ "$dry" == "would remove "* ]] || fail "unexpected dry run: $dry"
[ "$(entries "source trees")" = "$trees" ] || fail "a dry run removed trees"
"$swx" cache prune --older-than 0h >/dev/null
[ -z "$(entries "source trees")" ] || fail "trees of a deleted project survived"
mv "$work/Package.resolved.saved" "$work/package/Package.resolved"
(cd "$work/package" && swift build --disable-automatic-resolution -q) || fail "the project no longer builds from its checkouts"
echo "a forgotten project's entries go; its checkouts still build"

# The remote: files swx wrote expire, anything else stays.
echo "keep me" > "$remote/notes.txt"
[[ "$("$swx" cache size --remote "$remote" | tail -1)" == *"total"* ]] || fail "no remote size"
"$swx" cache prune --remote "$remote" --older-than 0h >/dev/null
[ -z "$(find "$remote/v1" -type f 2>/dev/null)" ] || fail "remote files survived a prune"
[ -f "$remote/notes.txt" ] || fail "a remote prune deleted a file swx didn't write"
echo "a directory remote is pruned of swx's files only"

# A copy of the binary installs a published release over itself, through the swift-x link.
if [ "$self_update" = "--self-update" ]; then
    mkdir -p "$work/bin"
    cp "$swx" "$work/bin/swx"
    ln -s swx "$work/bin/swift-x"
    "$work/bin/swift-x" self update --version "$update_tag" >/dev/null
    [ "$("$work/bin/swx" --version)" = "${update_tag#v}" ] || fail "self update didn't install $update_tag"
    [ -L "$work/bin/swift-x" ] || fail "self update replaced the swift-x link"
    echo "self update installed $update_tag"
fi
