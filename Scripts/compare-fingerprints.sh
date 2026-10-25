#!/usr/bin/env bash
# Differential check for git tag fingerprints (SwiftPM's `checkIntegrity`).
#
#   1. Resolving swift-argument-parser writes the same fingerprint file as SwiftPM
#      (`<security>/fingerprints/<identity>-<hash>.json`).
#   2. A package served by `git daemon` (a remote git:// URL, so fingerprints apply) has its
#      tag moved to another commit: with the recorded fingerprints, both tools must refuse it.
#
#   Scripts/compare-fingerprints.sh [swx-binary]
set -euo pipefail

swx_input="${1:-$(swift build -c release --show-bin-path)/swx}"
readonly swx="$(cd "$(dirname "$swx_input")" && pwd)/$(basename "$swx_input")"
readonly work="$(cd "$(mktemp -d)" && pwd -P)"
daemon=""
trap '[ -n "$daemon" ] && kill "$daemon" 2>/dev/null; rm -rf "$work"' EXIT

export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=user.email GIT_CONFIG_VALUE_0=fixture@example.com
export GIT_CONFIG_KEY_1=user.name GIT_CONFIG_VALUE_1=fixture

write_app() {
    local directory="$1" dependency="$2" product="$3" package="$4"
    rm -rf "$directory"
    mkdir -p "$directory/Sources/App"
    cat > "$directory/Package.swift" <<EOF
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "App",
    dependencies: [$dependency],
    targets: [.executableTarget(name: "App", dependencies: [.product(name: "$product", package: "$package")])]
)
EOF
    echo 'print(1)' > "$directory/Sources/App/main.swift"
}

# MARK: 1. Same fingerprint files as SwiftPM

readonly parser='.package(url: "https://github.com/apple/swift-argument-parser", exact: "1.5.0")'
write_app "$work/spm" "$parser" ArgumentParser swift-argument-parser
write_app "$work/swx" "$parser" ArgumentParser swift-argument-parser
(cd "$work/spm" && swift package resolve --security-path "$work/spm-security" >/dev/null 2>&1)
(cd "$work/swx" && "$swx" package resolve --security-path "$work/swx-security" >/dev/null)
diff -r "$work/spm-security/fingerprints" "$work/swx-security/fingerprints"
echo "fingerprints identical: $(ls "$work/swx-security/fingerprints")"

# MARK: 2. A moved tag is refused

mkdir -p "$work/served"
git init --quiet --initial-branch=main "$work/source"
mkdir -p "$work/source/Sources/Kit"
cat > "$work/source/Package.swift" <<'EOF'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Kit", products: [.library(name: "Kit", targets: ["Kit"])], targets: [.target(name: "Kit")])
EOF
echo 'public let kit = 1' > "$work/source/Sources/Kit/Kit.swift"
git -C "$work/source" add . && git -C "$work/source" commit --quiet -m one && git -C "$work/source" tag 1.0.0
git clone --quiet --bare "$work/source" "$work/served/kit.git"

readonly port=$((20000 + RANDOM % 20000))
git daemon --reuseaddr --base-path="$work/served" --export-all --listen=127.0.0.1 --port="$port" "$work/served" &
daemon=$!
sleep 1

readonly kit=".package(url: \"git://127.0.0.1:$port/kit.git\", from: \"1.0.0\")"
for tool in spm swx; do
    write_app "$work/$tool" "$kit" Kit kit
    rm -rf "$work/$tool-security"
done
(cd "$work/spm" && swift package resolve --security-path "$work/spm-security" --cache-path "$work/spm-cache" >/dev/null 2>&1)
(cd "$work/swx" && "$swx" package resolve --security-path "$work/swx-security" --cache-path "$work/swx-cache" >/dev/null)
diff -r "$work/spm-security/fingerprints" "$work/swx-security/fingerprints"
echo "git:// fingerprints identical"

# Move the tag on the server, then resolve again from scratch with the recorded fingerprints.
echo 'public let kit = 2' > "$work/source/Sources/Kit/Kit.swift"
git -C "$work/source" commit --quiet -am two && git -C "$work/source" tag --force 1.0.0 >/dev/null
git -C "$work/source" push --quiet --force "$work/served/kit.git" main 1.0.0
for tool in spm swx; do
    rm -rf "$work/$tool/.build" "$work/$tool/Package.resolved" "$work/$tool-cache"
done

if (cd "$work/spm" && swift package resolve --security-path "$work/spm-security" --cache-path "$work/spm-cache" >/dev/null 2>&1); then
    echo "SwiftPM accepted a moved tag" >&2
    exit 1
fi
if (cd "$work/swx" && "$swx" package resolve --security-path "$work/swx-security" --cache-path "$work/swx-cache" 2>"$work/swx-error" >/dev/null); then
    echo "swx accepted a moved tag" >&2
    exit 1
fi
echo "moved tag refused by both: $(head -1 "$work/swx-error")"
