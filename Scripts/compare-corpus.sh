#!/usr/bin/env bash
# Differential check over Corpus/packages.txt: each package becomes the sole dependency of a
# scratch root, resolved once by SwiftPM and once by swx (each with its own caches and security
# directory, so ~/.swiftpm is never touched). Package.resolved must be byte-identical,
# workspace-state.json identical up to the root's path (and SwiftPM's arbitrary order of a
# package's artifacts), and SwiftPM must accept swx's checkouts
# without changing anything. A package both tools refuse counts as agreement.
#
#   Scripts/compare-corpus.sh <work-dir> [swx-binary] [first-line] [last-line]
#
# <work-dir> keeps the caches between runs (later packages share earlier ones' repositories);
# results go to <work-dir>/results.txt, one line per package.
set -uo pipefail

readonly work="$(mkdir -p "$1" && cd "$1" && pwd -P)"
swx_input="${2:-$(swift build -c release --show-bin-path)/swx}"
readonly swx="$(cd "$(dirname "$swx_input")" && pwd)/$(basename "$swx_input")"
readonly first="${3:-1}"
readonly last="${4:-100000}"
readonly list="$(cd "$(dirname "$0")/.." && pwd)/Corpus/packages.txt"
readonly results="$work/results.txt"
readonly state_file=".build/workspace-state.json"

# Each tool's own shared locations.
for tool in spm swx; do
    mkdir -p "$work/$tool-cache" "$work/$tool-security" "$work/$tool-config"
done
spm_flags=(--cache-path "$work/spm-cache" --security-path "$work/spm-security" --config-path "$work/spm-config")
swx_flags=(--cache-path "$work/swx-cache" --security-path "$work/swx-security" --config-path "$work/swx-config")

# workspace-state.json with the root's path replaced, and artifacts in a fixed order: SwiftPM
# sorts them by package only, so within a package they follow its (randomly seeded) hashing.
canonical_state() {
    python3 -I -c 'import json, sys
state = json.load(open(sys.argv[1]))
state["object"]["artifacts"].sort(key=lambda a: (a["packageRef"]["identity"], a["targetName"]))
print(json.dumps(state, indent=2, sort_keys=True).replace(sys.argv[2], "ROOT"))' "$1" "$2"
}

# A root that depends on any release of `url`.
make_root() {
    local root="$1" url="$2"
    rm -rf "$root"
    mkdir -p "$root/Sources/Root"
    echo 'let x = 0' > "$root/Sources/Root/x.swift"
    cat > "$root/Package.swift" <<MANIFEST
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Root",
    dependencies: [.package(url: "$url", "0.0.1"..<"999.0.0")],
    targets: [.target(name: "Root")]
)
MANIFEST
}

compare() {
    local url="$1" name spm_root swx_root spm_ok=1 swx_ok=1
    name="$(basename "$url" .git)"
    spm_root="$work/roots/$name-spm"
    swx_root="$work/roots/$name-swx"
    make_root "$spm_root" "$url"
    make_root "$swx_root" "$url"

    (cd "$spm_root" && swift package resolve "${spm_flags[@]}" </dev/null >"$spm_root.log" 2>&1) || spm_ok=0
    (cd "$swx_root" && "$swx" package resolve "${swx_flags[@]}" </dev/null >"$swx_root.log" 2>&1) || swx_ok=0

    # Both refusing is agreement (a newer tools version, an unreachable dependency, …).
    if [ $spm_ok = 0 ] && [ $swx_ok = 0 ]; then
        echo "both-fail  $name"
        return
    fi
    if [ $spm_ok != $swx_ok ]; then
        echo "MISMATCH   $name: swiftpm $([ $spm_ok = 1 ] && echo resolved || echo failed), swx $([ $swx_ok = 1 ] && echo resolved || echo failed)"
        return
    fi

    # Same lockfile bytes, same state up to the root's path.
    if ! cmp -s "$spm_root/Package.resolved" "$swx_root/Package.resolved"; then
        echo "MISMATCH   $name: Package.resolved differs"
        return
    fi
    if ! diff -q <(canonical_state "$spm_root/$state_file" "$spm_root") <(canonical_state "$swx_root/$state_file" "$swx_root") >/dev/null; then
        echo "MISMATCH   $name: workspace-state.json differs"
        return
    fi

    # SwiftPM takes swx's checkouts as they are.
    cp "$swx_root/Package.resolved" "$swx_root/Package.resolved.swx"
    if ! (cd "$swx_root" && swift package resolve "${spm_flags[@]}" </dev/null >>"$swx_root.log" 2>&1) || ! cmp -s "$swx_root/Package.resolved" "$swx_root/Package.resolved.swx"; then
        echo "MISMATCH   $name: SwiftPM changed swx's resolution"
        return
    fi
    echo "identical  $name ($(grep -c '"identity"' "$swx_root/Package.resolved") pins)"
    rm -rf "$spm_root" "$swx_root"
}

mkdir -p "$work/roots"
grep -v '^#' "$list" | sed -n "${first},${last}p" | while read -r url; do
    [ -z "$url" ] && continue
    compare "$url" | tee -a "$results"
done

echo "---"
awk '{ print $1 }' "$results" | sort | uniq -c
