#!/usr/bin/env bash
# Runs inside a Linux Swift image: checks Git LFS files in dependencies against SwiftPM.
# Installs git-lfs, publishes a package whose resource is LFS-tracked to a local bare
# repository, resolves an app with SwiftPM and with swx, and compares the checkouts.
#
#   container run --rm --volume <dir with static swx>:/swx swift:6.4.1-noble bash /swx/lfs-check.sh
set -euo pipefail

readonly swx="${SWX:-/swx/swx}"
readonly work=/tmp/lfs
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=user.email GIT_CONFIG_VALUE_0=fixture@example.com
export GIT_CONFIG_KEY_1=user.name GIT_CONFIG_VALUE_1=fixture

apt-get update -qq >/dev/null && apt-get install -y -qq git-lfs >/dev/null
git lfs install --skip-repo >/dev/null

# A package with a 1 MB LFS-tracked resource.
mkdir -p "$work/pkg/Sources/Kit/Resources"
cd "$work/pkg"
git init --quiet --initial-branch=main
git lfs track "*.bin" >/dev/null
head -c 1048576 /dev/urandom > Sources/Kit/Resources/data.bin
cat > Package.swift <<'EOF'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Kit",
    products: [.library(name: "Kit", targets: ["Kit"])],
    targets: [.target(name: "Kit", resources: [.copy("Resources/data.bin")])]
)
EOF
echo 'public let kit = 1' > Sources/Kit/Kit.swift
git add . && git commit --quiet -m kit && git tag 1.0.0
# git-lfs moves objects to file:// remotes with its standalone transfer agent.
git init --quiet --bare "$work/pkg.git"
git remote add origin "file://$work/pkg.git"
git push --quiet origin main --tags 2>/dev/null
git lfs push --all origin >/dev/null 2>&1

# The same app for both tools.
for tool in spm swx; do
    mkdir -p "$work/$tool/Sources/App"
    cat > "$work/$tool/Package.swift" <<EOF
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "App",
    dependencies: [.package(url: "file://$work/pkg.git", from: "1.0.0")],
    targets: [.executableTarget(name: "App", dependencies: [.product(name: "Kit", package: "pkg")])]
)
EOF
    echo 'import Kit; print(kit)' > "$work/$tool/Sources/App/main.swift"
done

# Local repositories are recorded by plain path, from which git-lfs can't derive an endpoint;
# point both tools at the fixture's LFS store (real packages use HTTPS remotes).
export GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_2=lfs.url GIT_CONFIG_VALUE_2="file://$work/pkg.git"
(cd "$work/spm" && swift package resolve >/dev/null)
(cd "$work/swx" && "$swx" package resolve)

readonly resource=.build/checkouts/pkg/Sources/Kit/Resources/data.bin
cmp "$work/pkg/Sources/Kit/Resources/data.bin" "$work/spm/$resource"
cmp "$work/spm/$resource" "$work/swx/$resource"
echo "LFS content identical ($(wc -c < "$work/swx/$resource") bytes, not a pointer)"

diff "$work/spm/Package.resolved" "$work/swx/Package.resolved"
diff <(sed "s#$work/spm#R#g" "$work/spm/.build/workspace-state.json") <(sed "s#$work/swx#R#g" "$work/swx/.build/workspace-state.json")
echo "Package.resolved and workspace-state.json identical"
