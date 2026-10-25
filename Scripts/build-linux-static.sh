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
# Its own scratch path: building into .build would repoint .build/release at the Linux binary.
readonly scratch=".build/linux-static"

"$swift" build -c release --swift-sdk "$arch-swift-linux-musl" --scratch-path "$scratch" -Xswiftc -gnone
echo "$("$swift" build -c release --swift-sdk "$arch-swift-linux-musl" --scratch-path "$scratch" --show-bin-path)/swx"
