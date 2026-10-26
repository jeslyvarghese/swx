#!/usr/bin/env bash
# End-to-end check of `swx cache push|pull`: a package resolved into one store is pushed to a
# remote cache (a directory, then an HTTP server with a bearer token); an empty store pulls it
# back, and resolving then restores every checkout without running git.
#
#   Scripts/check-remote-cache.sh [swx-binary]
set -euo pipefail

readonly repo="$(cd "$(dirname "$0")/.." && pwd)"
swx_input="${1:-$(swift build -c release --show-bin-path)/swx}"
readonly swx="$(cd "$(dirname "$swx_input")" && pwd)/$(basename "$swx_input")"
readonly work="$(cd "$(mktemp -d)" && pwd -P)"
readonly token="swx-test-token"
server=""
# Stop the server, make the stores' read-only trees deletable, and keep the script's exit status.
trap 'status=$?; [ -n "$server" ] && { kill "$server"; wait "$server" || true; } 2>/dev/null; chmod -R u+w "$work"; rm -rf "$work"; exit $status' EXIT

# The sample package, resolved once into the "pushing" store.
mkdir -p "$work/package/Sources/App"
cp "$repo/Tests/Fixtures/sample/Package.swift" "$work/package/"
echo 'print("hi")' > "$work/package/Sources/App/main.swift"
(cd "$work/package" && SWX_CACHE_DIR="$work/store-push" "$swx" package resolve -q)

# Push, push again (nothing new), pull into an empty store, resolve without git.
round_trip() {
    local name="$1" remote="$2"
    export SWX_CACHE_DIR="$work/store-push"
    (cd "$work/package" && "$swx" cache push --remote "$remote" >/dev/null)
    local again
    again="$(cd "$work/package" && "$swx" cache push --remote "$remote")"
    [[ "$again" == "pushed 0 entries"* ]] || { echo "$name: second push uploaded again: $again"; exit 1; }

    export SWX_CACHE_DIR="$work/store-pull-$name"
    rm -rf "$work/package/.build"
    (cd "$work/package" && "$swx" cache pull --remote "$remote" >/dev/null)
    local spawns
    spawns="$(cd "$work/package" && SWX_TRACE=1 "$swx" package resolve 2>&1 | grep -c 'spawn git' || true)"
    [ "$spawns" = "0" ] || { echo "$name: resolve after pull ran git $spawns times"; exit 1; }
    echo "$name: pushed, pulled, resolved without git"
}

round_trip directory "file://$work/remote-directory"

# The HTTP server writes its port once listening.
python3 -I "$repo/Scripts/test-cache-server.py" "$work/remote-http" "$work/port" "$token" &
server=$!
for _ in $(seq 100); do [ -s "$work/port" ] && break; sleep 0.1; done
[ -s "$work/port" ] || { echo "the test cache server did not start" >&2; exit 1; }
readonly http="http://127.0.0.1:$(cat "$work/port")/cache"

SWX_REMOTE_CACHE_TOKEN="$token" round_trip http "$http"

# A wrong token is an error, not a silent miss.
if (cd "$work/package" && SWX_CACHE_DIR="$work/store-wrong" SWX_REMOTE_CACHE_TOKEN=wrong "$swx" cache pull --remote "$http" >/dev/null 2>&1); then
    echo "http: a wrong token was accepted"
    exit 1
fi
echo "http: a wrong token is refused"
