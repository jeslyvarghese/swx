#!/usr/bin/env bash
# End-to-end check of `swx cache push|pull`: a package resolved into one store is pushed to a
# remote cache (a directory, then an HTTP server with a bearer token); an empty store pulls it
# back, and resolving then restores every checkout without running git. Last, build outputs
# pushed with --build are restored into an empty store, and no dependency rebuilds.
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

# Build outputs: built and pushed from one store, restored into an empty one at the same path.
# After the restore, building may recompile the package's own target, never a dependency's Swift.
# (SwiftPM's native build system reruns C compiles whenever file identities change, so those are
# counted, not failed.)
export SWX_CACHE_DIR="$work/store-push"
remote="file://$work/remote-directory"
(cd "$work/package" && swift build >/dev/null && "$swx" cache push --build --remote "$remote" >/dev/null)
rm -rf "$work/package/.build"
export SWX_CACHE_DIR="$work/store-build"
pulled="$(cd "$work/package" && "$swx" cache pull --build --remote "$remote")"
[[ "$pulled" == *"build: restored .build"*"built from these sources"* ]] || { echo "build: not restored: $pulled"; exit 1; }
(cd "$work/package" && "$swx" package resolve -q)
touch "$work/restored"
(cd "$work/package" && swift build >/dev/null)
objects="$(find "$work/package/.build" -name '*.o' | wc -l | tr -d ' ')"
[ "$objects" -gt 0 ] || { echo "build: no object files to compare"; exit 1; }
readonly c_family='\.(c|m|mm|cc|cpp|cxx|s|S)\.o$'
rebuilt="$(find "$work/package/.build" -name '*.o' -newer "$work/restored" | grep -v '/App' || true)"
rebuilt_swift="$(echo "$rebuilt" | grep -Ev "$c_family" | grep . || true)"
rebuilt_c="$(echo "$rebuilt" | grep -Ec "$c_family" || true)"
[ -z "$rebuilt_swift" ] || { echo "build: dependencies' Swift rebuilt after a restore:"; echo "$rebuilt_swift" | head; exit 1; }
echo "build: restored $objects object files; no dependency's Swift rebuilt ($rebuilt_c C objects recompiled)"
