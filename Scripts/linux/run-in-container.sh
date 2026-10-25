#!/usr/bin/env bash
# Builds a static Linux swx and runs Scripts/linux/workflow.sh in the official Swift image,
# using Apple's `container` CLI (brew install container) or Docker.
#
#   Scripts/linux/run-in-container.sh <swift.org toolchain swift binary> <fixture dir>
set -euo pipefail

readonly swift="$1"
readonly fixtures="$(cd "$2" && pwd)"
readonly image="docker.io/library/swift:6.4.1-noble"
readonly root="$(cd "$(dirname "$0")/../.." && pwd)"
readonly bin="$(mktemp -d)"

"$swift" build -c release --swift-sdk aarch64-swift-linux-musl --package-path "$root" -Xswiftc -gnone
cp "$("$swift" build -c release --swift-sdk aarch64-swift-linux-musl --package-path "$root" --show-bin-path)/swx" "$bin/swx"
cp "$root/Scripts/linux/workflow.sh" "$bin/workflow.sh"

runner=container
command -v container >/dev/null || runner=docker
"$runner" run --rm --volume "$bin:/swx" --volume "$fixtures:/work" "$image" bash /swx/workflow.sh
