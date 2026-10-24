#!/usr/bin/env bash
# Builds a fully static Linux binary of swx with the Static Linux SDK (musl).
# Requires a swift.org toolchain matching the installed SDK, e.g.:
#   swx toolchain install 6.4.1
#   swift sdk install <swift-6.4.1-RELEASE_static-linux-…artifactbundle.tar.gz>
#
#   Scripts/build-linux-static.sh [aarch64|x86_64] [path/to/toolchain/usr/bin/swift]
set -euo pipefail

readonly arch="${1:-aarch64}"
readonly swift="${2:-swift}"

"$swift" build -c release --swift-sdk "$arch-swift-linux-musl" -Xswiftc -gnone
echo "$("$swift" build -c release --swift-sdk "$arch-swift-linux-musl" --show-bin-path)/swx"
