#!/usr/bin/env bash
# Differential check for registry package signatures (SE-0391) against SwiftPM.
#
# Creates a test PKI with openssl (a P-256 root and a code-signing leaf), signs a release with
# `swift package-registry publish --dry-run`, serves it with Scripts/test-registry.py, and
# resolves it with SwiftPM and with swx under four policies:
#   untrusted        the root is not trusted: both warn and continue
#   trusted          trustedRootCertificatesPath holds the root: the signature is valid
#   untrusted-error  onUntrustedCertificate = error: both refuse
#   tampered         the signature bytes are corrupted: both refuse
# Exit codes must agree; where both succeed, Package.resolved, workspace-state.json,
# .registry-metadata (with the signer) and the fingerprints must be identical.
#
#   Scripts/compare-registry-signing.sh [swx-binary]
set -euo pipefail

swx_input="${1:-$(swift build -c release --show-bin-path)/swx}"
readonly swx="$(cd "$(dirname "$swx_input")" && pwd)/$(basename "$swx_input")"
readonly root="$(cd "$(dirname "$0")/.." && pwd)"
readonly work="$(cd "$(mktemp -d)" && pwd -P)"
server=""
trap '[ -n "$server" ] && kill "$server" 2>/dev/null; rm -rf "$work"' EXIT

# MARK: Test PKI

mkdir -p "$work/pki" "$work/trusted"
cd "$work/pki"
openssl ecparam -name prime256v1 -genkey -noout -out root.key 2>/dev/null
openssl req -x509 -new -key root.key -sha256 -days 3650 -subj "/CN=Test Root/O=Example" \
    -addext "basicConstraints=critical,CA:true" -addext "keyUsage=critical,keyCertSign,cRLSign" -out root.pem 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out leaf.key 2>/dev/null
openssl req -new -key leaf.key -subj "/CN=Mona Signer/OU=Team42/O=Example Org" -out leaf.csr 2>/dev/null
printf "basicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n" > leaf.ext
openssl x509 -req -in leaf.csr -CA root.pem -CAkey root.key -CAcreateserial -days 3650 -sha256 -extfile leaf.ext -out leaf.pem 2>/dev/null
openssl x509 -in root.pem -outform der -out root.der
openssl x509 -in leaf.pem -outform der -out leaf.der
openssl pkcs8 -topk8 -nocrypt -in leaf.key -outform der -out leaf.p8
cp root.der "$work/trusted/root.der"

# MARK: A release signed by SwiftPM

mkdir -p "$work/source/Sources/Signed" "$work/signed"
cd "$work/source"
printf '// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: "Signed", products: [.library(name: "Signed", targets: ["Signed"])], targets: [.target(name: "Signed")])\n' > Package.swift
echo 'public let signed = 1' > Sources/Signed/Signed.swift
git init --quiet && git add . && git -c user.email=fixture@example.com -c user.name=fixture commit --quiet -m signed
swift package-registry publish mona.Signed 1.0.0 --url http://127.0.0.1:1 --allow-insecure-http --dry-run \
    --scratch-directory "$work/signed" --private-key-path "$work/pki/leaf.p8" --cert-chain-paths "$work/pki/leaf.der" "$work/pki/root.der" >/dev/null

readonly release="$work/packages/mona/Signed"
mkdir -p "$release/1.0.0"
cp "$work/signed/mona.Signed-1.0.0.zip" "$release/1.0.0.zip"
cp "$work/signed/mona.Signed-1.0.0.sig" "$release/1.0.0.sig"
cp -R "$work/signed/source/mona.Signed/." "$release/1.0.0/"

python3 -I "$root/Scripts/test-registry.py" --root "$work/packages" > "$work/port" &
server=$!
# The server prints its port once every archive is built: slow runners need well over 5 s.
for _ in $(seq 600); do [ -s "$work/port" ] && break; kill -0 "$server" 2>/dev/null || break; sleep 0.1; done
[ -s "$work/port" ] || { echo "the test registry did not start" >&2; exit 1; }
readonly port="$(cat "$work/port")"

# MARK: Scenarios

# Resolves one scenario with one tool; prints the exit status.
resolve() {
    local tool="$1" name="$2" security="$3"
    local app="$work/$tool/$name"
    mkdir -p "$app/Sources/App" "$app/.swiftpm/configuration" "$work/$tool/$name-config"
    cat > "$app/Package.swift" <<'EOF'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "App", dependencies: [.package(id: "mona.Signed", from: "1.0.0")],
  targets: [.executableTarget(name: "App", dependencies: [.product(name: "Signed", package: "mona.Signed")])])
EOF
    echo 'import Signed; print(signed)' > "$app/Sources/App/main.swift"
    echo "{\"registries\": {\"[default]\": {\"supportsAvailability\": false, \"url\": \"http://127.0.0.1:$port\"}}, $security \"version\": 1}" \
        > "$app/.swiftpm/configuration/registries.json"

    local command=(swift package resolve)
    [ "$tool" = swx ] && command=("$swx" package resolve)
    local status=0
    (cd "$app" && "${command[@]}" --config-path "$work/$tool/$name-config" --security-path "$work/$tool/$name-security" \
        --cache-path "$work/$tool/$name-cache" > "$work/$tool/$name.log" 2>&1) || status=$?
    echo "$status"
}

compare() {
    local name="$1" security="$2"
    local spm swxStatus
    spm=$(resolve spm "$name" "$security")
    swxStatus=$(resolve swx "$name" "$security")
    if [ "$spm" != "$swxStatus" ]; then
        echo "$name: SwiftPM exited $spm, swx exited $swxStatus" >&2
        tail -5 "$work/swx/$name.log" >&2
        exit 1
    fi
    if [ "$spm" = 0 ]; then
        local a="$work/spm/$name" b="$work/swx/$name"
        diff "$a/Package.resolved" "$b/Package.resolved"
        diff <(sed "s#$work/spm#R#g" "$a/.build/workspace-state.json") <(sed "s#$work/swx#R#g" "$b/.build/workspace-state.json")
        diff "$a/.build/registry/downloads/mona/Signed/1.0.0/.registry-metadata" "$b/.build/registry/downloads/mona/Signed/1.0.0/.registry-metadata"
        diff -r "$work/spm/$name-security/fingerprints" "$work/swx/$name-security/fingerprints"
        echo "$name: both succeed; lockfile, state, .registry-metadata and fingerprints identical"
    else
        echo "$name: both refuse ($(grep -m1 'error' "$work/swx/$name.log" | cut -c1-110))"
    fi
}

readonly trusted="\"security\": {\"default\": {\"signing\": {\"trustedRootCertificatesPath\": \"$work/trusted\"}}},"
compare untrusted ''
compare trusted "$trusted"
compare untrusted-error '"security": {"default": {"signing": {"onUntrustedCertificate": "error"}}},'

# Corrupt the signature value (its last bytes), keeping the CMS structure parseable.
python3 -I -c "import sys; p=sys.argv[1]; d=bytearray(open(p,'rb').read()); d[-3]^=0xFF; open(p,'wb').write(bytes(d))" "$release/1.0.0.sig"
compare tampered "$trusted"
