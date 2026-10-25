#!/bin/sh
# Installs the latest swx release (or SWX_VERSION) for this OS and CPU.
#
#   curl -fsSL https://jeslyvarghese.github.io/swx/install.sh | sh
#
# Environment:
#   SWX_VERSION       a release tag such as v0.1.0 (default: the latest release)
#   SWX_INSTALL_DIR   where to put the binary (default: ~/.local/bin)
#   SWX_DOWNLOAD_URL  a mirror of the release assets (default: the GitHub release)
set -eu

readonly repository="jeslyvarghese/swx"
readonly checksums="SHA256SUMS"
readonly install_dir="${SWX_INSTALL_DIR:-$HOME/.local/bin}"

fail() {
    echo "swx install: $*" >&2
    exit 1
}

# The release asset for this machine: one universal macOS binary, static Linux binaries per CPU.
case "$(uname -s)" in
    Darwin) asset="swx-macos-universal.tar.gz" ;;
    Linux)
        case "$(uname -m)" in
            x86_64 | amd64) asset="swx-linux-x86_64.tar.gz" ;;
            aarch64 | arm64) asset="swx-linux-aarch64.tar.gz" ;;
            *) fail "no Linux build for $(uname -m)" ;;
        esac
        ;;
    *) fail "no build for $(uname -s); build from source with 'swift build -c release'" ;;
esac

if [ -n "${SWX_DOWNLOAD_URL:-}" ]; then
    base="$SWX_DOWNLOAD_URL"
elif [ -n "${SWX_VERSION:-}" ]; then
    base="https://github.com/$repository/releases/download/$SWX_VERSION"
else
    base="https://github.com/$repository/releases/latest/download"
fi

# Download into a private directory, removed on exit.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
command -v curl >/dev/null || fail "curl is required"
curl -fsSL "$base/$asset" -o "$work/$asset" || fail "could not download $base/$asset"
curl -fsSL "$base/$checksums" -o "$work/$checksums" || fail "could not download $base/$checksums"

# The archive must match the release's published checksum.
expected="$(awk -v name="$asset" '$2 == name { print $1 }' "$work/$checksums")"
[ -n "$expected" ] || fail "$asset is not listed in $checksums"
if command -v sha256sum >/dev/null; then
    actual="$(sha256sum "$work/$asset" | awk '{ print $1 }')"
else
    actual="$(shasum -a 256 "$work/$asset" | awk '{ print $1 }')"
fi
[ "$expected" = "$actual" ] || fail "checksum mismatch for $asset (expected $expected, got $actual)"

# Install swx, and swift-x so that `swift x …` works through SwiftPM's subcommand lookup.
tar -xzf "$work/$asset" -C "$work"
mkdir -p "$install_dir"
install -m 0755 "$work/swx" "$install_dir/swx"
ln -sf swx "$install_dir/swift-x"
echo "installed $("$install_dir/swx" --version | head -1) to $install_dir/swx"

case ":$PATH:" in
    *":$install_dir:"*) ;;
    *) echo "add $install_dir to your PATH, e.g.: export PATH=\"$install_dir:\$PATH\"" ;;
esac
