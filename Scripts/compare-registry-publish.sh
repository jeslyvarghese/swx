#!/usr/bin/env bash
# Differential check of `swx publish` against `swift package-registry publish` (SE-0391).
#
# One package (a version-specific manifest, package-metadata.json, .gitignore, .swiftpm, a git
# repository, a symlink) is published, signed with a test PKI, by SwiftPM to one test registry
# and by swx to another. Then:
# - the dry runs leave the same working files;
# - the requests carry the same headers and the same parts, with the same part headers;
# - the archives hold the same files, byte for byte apart from the manifests' signature lines,
#   and the metadata is identical;
# - SwiftPM and swx both resolve swx's release with the root trusted and untrusted signers
#   refused, so swx's signatures (archive and manifests) are valid where SwiftPM checks them;
# - a release signed with --signing-identity (a Keychain identity, from a throwaway keychain the
#   user's search list never sees) is accepted by SwiftPM, signer and all;
# - unsigned publishes match too, and both refuse plain HTTP without --allow-insecure-http.
#
#   Scripts/compare-registry-publish.sh [swx-binary]
set -euo pipefail

swx_input="${1:-$(swift build -c release --show-bin-path)/swx}"
readonly swx="$(cd "$(dirname "$swx_input")" && pwd)/$(basename "$swx_input")"
readonly repo="$(cd "$(dirname "$0")/.." && pwd)"
readonly work="$(cd "$(mktemp -d)" && pwd -P)"
servers=()
readonly keychain="$work/signing.keychain-db"
# Stop the registries quietly, drop the test keychain, and keep the script's exit status.
trap 'status=$?; for pid in "${servers[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done; [ -f "$keychain" ] && security delete-keychain "$keychain"; chmod -R u+w "$work"; rm -rf "$work"; exit $status' EXIT

fail() {
    echo "compare-registry-publish: $*" >&2
    exit 1
}

# MARK: Test PKI (as in compare-registry-signing.sh)

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
mkdir -p "$work/publish-config"
readonly signing=(--private-key-path "$work/pki/leaf.p8" --cert-chain-paths "$work/pki/leaf.der" "$work/pki/root.der")

# MARK: The package

readonly package="$work/package"
mkdir -p "$package/Sources/Pub" "$package/.swiftpm/xcode" "$package/docs"
cd "$package"
printf '// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: "Pub", products: [.library(name: "Pub", targets: ["Pub"])], targets: [.target(name: "Pub")])\n' > Package.swift
printf '// swift-tools-version: 5.8\nimport PackageDescription\nlet package = Package(name: "Pub", products: [.library(name: "Pub", targets: ["Pub"])], targets: [.target(name: "Pub")])\n' > Package@swift-5.8.swift
echo 'public let published = 1' > Sources/Pub/Pub.swift
echo '{"author": {"name": "Mona"}, "description": "A published fixture", "licenseURL": "https://example.com/LICENSE"}' > package-metadata.json
echo '.build/' > .gitignore
echo 'hidden' > .env
echo '# Pub' > docs/README.md
ln -s docs/README.md README.md
echo '{}' > .swiftpm/xcode/settings.json
git init --quiet && git add . && git -c user.email=fixture@example.com -c user.name=fixture commit --quiet -m pub

# MARK: Registries

# Starts a test registry over `root`, recording uploads; sets `port`.
start_registry() {
    local root="$1" uploads="$2"
    mkdir -p "$root"
    # Its output goes to files, and it leaves the job table, so stopping it is silent.
    python3 -I "$repo/Scripts/test-registry.py" --root "$root" --uploads "$uploads" > "$root.port" 2> "$root.log" &
    servers+=($!)
    disown $!
    for _ in $(seq 600); do [ -s "$root.port" ] && break; sleep 0.1; done
    [ -s "$root.port" ] || fail "a test registry did not start"
    port="$(cat "$root.port")"
}
start_registry "$work/registry-spm" "$work/uploads-spm"
readonly spm_port="$port"
start_registry "$work/registry-swx" "$work/uploads-swx"
readonly swx_port="$port"

# MARK: Dry runs leave the same working files

mkdir -p "$work/dry-spm" "$work/dry-swx"
swift package-registry publish --config-path "$work/publish-config" mona.Pub 1.0.0 --url "http://127.0.0.1:$spm_port" --allow-insecure-http --dry-run \
    --scratch-directory "$work/dry-spm" "${signing[@]}" >/dev/null
"$swx" publish --config-path "$work/publish-config" mona.Pub 1.0.0 --url "http://127.0.0.1:$swx_port" --allow-insecure-http --dry-run \
    --scratch-directory "$work/dry-swx" "${signing[@]}" >/dev/null
diff <(cd "$work/dry-spm" && find . | sort) <(cd "$work/dry-swx" && find . | sort) || fail "dry runs left different working files"
echo "dry runs leave the same working files"

# MARK: Signed publishes

swift package-registry publish --config-path "$work/publish-config" mona.Pub 1.0.0 --url "http://127.0.0.1:$spm_port" --allow-insecure-http \
    --scratch-directory "$work/dry-spm" "${signing[@]}" >/dev/null
"$swx" publish --config-path "$work/publish-config" mona.Pub 1.0.0 --url "http://127.0.0.1:$swx_port" --allow-insecure-http \
    --scratch-directory "$work/dry-swx" "${signing[@]}" >/dev/null

# Same headers and parts.
readonly record="mona.Pub-1.0.0"
diff "$work/uploads-spm/$record.json" "$work/uploads-swx/$record.json" || fail "the publish requests differ"
cmp -s "$work/uploads-spm/$record.metadata" "$work/uploads-swx/$record.metadata" || fail "the metadata differs"
echo "requests carry the same headers, parts and metadata"

# Same archive contents, manifests compared without their signature lines.
compare_archives() {
    local spm_zip="$1" swx_zip="$2" label="$3"
    rm -rf "$work/unzip-spm" "$work/unzip-swx"
    mkdir -p "$work/unzip-spm" "$work/unzip-swx"
    (cd "$work/unzip-spm" && unzip -q "$spm_zip")
    (cd "$work/unzip-swx" && unzip -q "$swx_zip")
    diff <(unzip -Z1 "$spm_zip" | sort) <(unzip -Z1 "$swx_zip" | sort) || fail "$label: the archives list different files"
    for manifest in Package.swift Package@swift-5.8.swift; do
        local path="mona.Pub/$manifest"
        diff <(sed '/^\/\/ signature: /d' "$work/unzip-spm/$path") <(sed '/^\/\/ signature: /d' "$work/unzip-swx/$path") || fail "$label: $manifest differs"
        rm "$work/unzip-spm/$path" "$work/unzip-swx/$path"
    done
    diff -r "$work/unzip-spm" "$work/unzip-swx" || fail "$label: archived files differ"
    [ -L "$work/unzip-swx/mona.Pub/README.md" ] || fail "$label: the symlink was not kept"
}
compare_archives "$work/uploads-spm/$record.source-archive" "$work/uploads-swx/$record.source-archive" signed
echo "archives hold the same files"

# MARK: Resolving swx's release checks its signatures

# Resolves mona.Pub from the registry on `port` with one tool, trusting the test root and
# refusing untrusted signers; prints the signer recorded in .registry-metadata.
resolve() {
    local tool="$1" port="$2" version="${3:-1.0.0}"
    local app="$work/apps/$tool-$port-$version"
    mkdir -p "$app/Sources/App" "$app/.swiftpm/configuration"
    cat > "$app/Package.swift" <<EOF
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "App", dependencies: [.package(id: "mona.Pub", exact: "$version")],
  targets: [.executableTarget(name: "App", dependencies: [.product(name: "Pub", package: "mona.Pub")])])
EOF
    echo 'import Pub; print(published)' > "$app/Sources/App/main.swift"
    echo "{\"registries\": {\"[default]\": {\"supportsAvailability\": false, \"url\": \"http://127.0.0.1:$port\"}}, \"security\": {\"default\": {\"signing\": {\"onUnsigned\": \"error\", \"onUntrustedCertificate\": \"error\", \"trustedRootCertificatesPath\": \"$work/trusted\"}}}, \"version\": 1}" \
        > "$app/.swiftpm/configuration/registries.json"
    local flags=(--cache-path "$work/$tool-cache" --security-path "$work/$tool-security-$port-$version" --config-path "$work/$tool-config")
    mkdir -p "$work/$tool-config"
    if [ "$tool" = swiftpm ]; then
        (cd "$app" && swift package resolve "${flags[@]}" >/dev/null 2>&1) || fail "SwiftPM refused the release on port $port"
    else
        (cd "$app" && "$swx" package resolve "${flags[@]}" >/dev/null 2>&1) || fail "swx refused the release on port $port"
    fi
    # `signedBy` holds one entry keyed by the signer's kind (`unrecognized` for a test PKI).
    python3 -c 'import json, sys; signer = json.load(open(sys.argv[1])).get("signature", {}).get("signedBy", {}); print(next(iter(signer.values()), {}).get("commonName", "unsigned"))' \
        "$app/.build/registry/downloads/mona/Pub/$version/.registry-metadata"
}
for tool in swiftpm swx; do
    signer="$(resolve "$tool" "$swx_port")"
    [ "$signer" = "Mona Signer" ] || fail "$tool recorded signer '$signer' for swx's release"
done
echo "SwiftPM and swx accept swx's signatures (signed by Mona Signer)"

# MARK: A Keychain identity

# The leaf and its key in a throwaway keychain; SWX_SIGNING_KEYCHAIN keeps the lookup to it.
openssl pkcs12 -export -inkey "$work/pki/leaf.key" -in "$work/pki/leaf.pem" -out "$work/pki/leaf.p12" -passout pass:swx -legacy 2>/dev/null \
    || openssl pkcs12 -export -inkey "$work/pki/leaf.key" -in "$work/pki/leaf.pem" -out "$work/pki/leaf.p12" -passout pass:swx
security create-keychain -p swx "$keychain"
security unlock-keychain -p swx "$keychain"
security set-keychain-settings "$keychain"
security import "$work/pki/leaf.p12" -k "$keychain" -P swx -A >/dev/null
security set-key-partition-list -S apple-tool:,apple:,unsigned: -s -k swx "$keychain" >/dev/null 2>&1
mkdir -p "$work/dry-keychain"
SWX_SIGNING_KEYCHAIN="$keychain" "$swx" publish --config-path "$work/publish-config" mona.Pub 1.1.0 --url "http://127.0.0.1:$swx_port" --allow-insecure-http \
    --scratch-directory "$work/dry-keychain" --signing-identity "Mona Signer" >/dev/null || fail "publishing with --signing-identity failed"
signer="$(resolve swiftpm "$swx_port" 1.1.0)"
[ "$signer" = "Mona Signer" ] || fail "SwiftPM recorded signer '$signer' for the Keychain-signed release"
echo "SwiftPM accepts a release signed with a Keychain identity"

# MARK: Unsigned, and plain HTTP

swift package-registry publish --config-path "$work/publish-config" mona.Pub 2.0.0 --url "http://127.0.0.1:$spm_port" --allow-insecure-http --scratch-directory "$work/dry-spm" >/dev/null
"$swx" publish --config-path "$work/publish-config" mona.Pub 2.0.0 --url "http://127.0.0.1:$swx_port" --allow-insecure-http --scratch-directory "$work/dry-swx" >/dev/null
diff "$work/uploads-spm/mona.Pub-2.0.0.json" "$work/uploads-swx/mona.Pub-2.0.0.json" || fail "the unsigned publish requests differ"
compare_archives "$work/uploads-spm/mona.Pub-2.0.0.source-archive" "$work/uploads-swx/mona.Pub-2.0.0.source-archive" unsigned
echo "unsigned publishes match"

spm_status=0
swx_status=0
swift package-registry publish --config-path "$work/publish-config" mona.Pub 3.0.0 --url "http://127.0.0.1:$spm_port" --scratch-directory "$work/dry-spm" >/dev/null 2>&1 || spm_status=$?
"$swx" publish --config-path "$work/publish-config" mona.Pub 3.0.0 --url "http://127.0.0.1:$swx_port" --scratch-directory "$work/dry-swx" >/dev/null 2>&1 || swx_status=$?
[ $spm_status != 0 ] && [ $swx_status != 0 ] || fail "plain HTTP without --allow-insecure-http: SwiftPM exited $spm_status, swx $swx_status"
echo "both refuse plain HTTP without --allow-insecure-http"
