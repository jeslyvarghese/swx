#!/usr/bin/env bash
# Differential check: resolve one package with SwiftPM and with swx, each from an
# empty cache, then diff Package.resolved and workspace-state.json and print timings.
#
#   Scripts/compare-with-swiftpm.sh <package-dir> [swx-binary]
set -euo pipefail

readonly package_dir="$(cd "$1" && pwd)"
swx_input="${2:-$(swift build -c release --show-bin-path)/swx}"
readonly swx="$(cd "$(dirname "$swx_input")" && pwd)/$(basename "$swx_input")"
readonly work="$(mktemp -d)"
readonly state_file=".build/workspace-state.json"
trap 'rm -rf "$work"' EXIT

# Fresh copies of the package (sources and manifest only), one per tool.
copy_package() {
    mkdir -p "$1"
    rsync -a --exclude .build --exclude Package.resolved "$package_dir/" "$1/"
}
copy_package "$work/spm"
copy_package "$work/swx"

# Time a command in seconds (BSD date has no sub-second format, so use python).
now() { python3 -c 'import time; print(time.time())'; }
timed() {
    local start
    start=$(now)
    "$@" >/dev/null 2>&1
    python3 -c "print($(now) - $start)"
}

echo "== $(basename "$package_dir")"
spm_cold=$(cd "$work/spm" && timed swift package resolve --cache-path "$work/spm-cache")
swx_cold=$(cd "$work/swx" && timed "$swx" package resolve --cache-path "$work/swx-cache")
printf 'cold resolve   swiftpm %6.2fs   swx %6.2fs\n' "$spm_cold" "$swx_cold"

# Package.resolved must match exactly.
status=0
if diff -u "$work/spm/Package.resolved" "$work/swx/Package.resolved"; then
    echo "Package.resolved      identical"
else
    echo "Package.resolved      DIFFERS"
    status=1
fi

# Workspace state may only differ in the absolute package path.
normalize() { sed -e "s#$work/spm#ROOT#g" -e "s#$work/swx#ROOT#g" "$1"; }
if diff -u <(normalize "$work/spm/$state_file") <(normalize "$work/swx/$state_file"); then
    echo "workspace-state.json  identical"
else
    echo "workspace-state.json  DIFFERS"
    status=1
fi

# SwiftPM must accept swx's checkouts without re-resolving.
if (cd "$work/swx" && swift package resolve >/dev/null 2>&1) && diff -q "$work/spm/Package.resolved" "$work/swx/Package.resolved" >/dev/null; then
    echo "swiftpm accepts swx checkouts"
else
    echo "swiftpm REJECTED swx checkouts"
    status=1
fi

exit $status
