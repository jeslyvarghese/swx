#!/usr/bin/env bash
# Differential check: `swx package show-dependencies` against SwiftPM's, byte for byte, in every
# format, prebuilt swift-syntax included; then `swx graph` in every format at both levels, with Graphviz accepting its dot output
# when `dot` is installed.
#
#   Scripts/compare-graph.sh [swx-binary] [package-dir …]   (default: the sample and graph fixtures)
set -euo pipefail

readonly repo="$(cd "$(dirname "$0")/.." && pwd)"
swx_input="${1:-$(swift build -c release --show-bin-path)/swx}"
readonly swx="$(cd "$(dirname "$swx_input")" && pwd)/$(basename "$swx_input")"
shift || true
packages=("$@")
# The macro fixtures check SwiftPM's swap of swift-syntax for its prebuilt libraries (or not).
[ ${#packages[@]} -eq 0 ] && packages=("$repo/Tests/Fixtures/sample" "$repo/Tests/Fixtures/graph" "$repo/Tests/Fixtures/macros" "$repo/Tests/Fixtures/macros-mixed")
readonly work="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$work"' EXIT

readonly formats=(text dot json flatlist)
readonly graph_formats=(text dot mermaid json)
readonly levels=(target package)
status=0

# SwiftPM prints a package's traits in Set order, which changes from run to run; swx sorts them.
# Everything else is compared byte for byte.
cat > "$work/sort-traits.py" <<'EOF'
import re, sys

text = open(sys.argv[1]).read()
# text: `(traits: b, a)`
text = re.sub(r"\(traits: ([^)]*)\)", lambda m: "(traits: " + ", ".join(sorted(m.group(1).split(", "))) + ")", text)
# json: the string lines of a `"traits": [ … ]` block
def sort_block(match):
    lines = match.group(2).split("\n")
    indent = re.match(r"\s*", lines[0]).group(0)
    names = sorted(line.strip().rstrip(",") for line in lines)
    return match.group(1) + ",\n".join(indent + name for name in names) + match.group(3)
text = re.sub(r'("traits": \[\n)((?:\s*"[^"\n]*",?\n?)+?)(\n\s*\])', sort_block, text)
sys.stdout.write(text)
EOF

for package in "${packages[@]}"; do
    name="$(basename "$package")"
    copy="$work/$name"
    mkdir -p "$copy"
    rsync -a --exclude .build --exclude Package.resolved "$package/" "$copy/"
    echo "== $name"

    # swx resolves; both tools then read the same checkouts.
    (cd "$copy" && "$swx" package resolve -q)

    for format in "${formats[@]}"; do
        (cd "$copy" && swift package show-dependencies --format "$format" 2>/dev/null) | python3 -I "$work/sort-traits.py" /dev/stdin > "$work/spm.$format"
        (cd "$copy" && "$swx" package show-dependencies --format "$format") > "$work/swx.raw.$format"
        python3 -I "$work/sort-traits.py" "$work/swx.raw.$format" > "$work/swx.$format"

        # swx's own output must already be sorted: normalizing it changes nothing.
        cmp -s "$work/swx.raw.$format" "$work/swx.$format" || { echo "swx printed unsorted traits"; status=1; }
        if cmp -s "$work/spm.$format" "$work/swx.$format"; then
            printf 'show-dependencies --format %-9s identical\n' "$format"
        else
            printf 'show-dependencies --format %-9s DIFFERS\n' "$format"
            diff "$work/spm.$format" "$work/swx.$format" | head -20 || true
            status=1
        fi
    done

    # `swx graph` prints every format at both levels, and its JSON parses.
    for level in "${levels[@]}"; do
        for format in "${graph_formats[@]}"; do
            (cd "$copy" && "$swx" graph --level "$level" --format "$format" > "$work/graph.$level.$format")
        done
    done
    python3 -I -c 'import json, sys; [json.load(open(path)) for path in sys.argv[1:]]' "$work"/graph.*.json
    echo "swx graph: every format at both levels"

    # Graphviz must accept the dot output, and `-o *.svg` must draw through it.
    command -v dot >/dev/null || continue
    for level in "${levels[@]}"; do
        dot -Tsvg "$work/graph.$level.dot" -o /dev/null
    done
    (cd "$copy" && "$swx" graph -o "$work/graph.svg")
    [ -s "$work/graph.svg" ]
    echo "graphviz: accepts the dot output and draws -o graph.svg"
done

exit $status
