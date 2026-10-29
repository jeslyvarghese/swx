<h1 align="center">swx</h1>

<p align="center">
  <a href="https://github.com/jeslyvarghese/swx/actions/workflows/ci.yml"><img src="https://github.com/jeslyvarghese/swx/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/jeslyvarghese/swx/releases/latest"><img src="https://img.shields.io/github/v/release/jeslyvarghese/swx" alt="Latest release"></a>
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/license-Apache%202.0-blue" alt="License"></a>
</p>

<p align="center">
  <b>
    <a href="https://swx.quadratic.xyz/">Website</a>
    |
    <a href="https://swx.quadratic.xyz/guide.html">User guide</a>
    |
    <a href="https://github.com/jeslyvarghese/swx/releases">Releases</a>
    |
    <a href="CONTRIBUTING.md">Contributing</a>
  </b>
</p>

## swx: a fast, drop-in companion to SwiftPM

What `uv` is to `pip`, for Swift. swx resolves, builds and runs Swift packages, and writes
SwiftPM's own files byte for byte, so `swx`, `swift` and Xcode can be mixed freely.

- **Fast**: cold resolves about 4× faster than SwiftPM, no-ops in 20 ms
- **Drop-in**: the same `Package.resolved`, `.build/checkouts` and `workspace-state.json`
- **Nothing to migrate**: reads `Package.swift` as is, honours SwiftPM's flags and configuration
- **Xcode-aware**: prepares `SourcePackages` so `xcodebuild` builds offline
- **Apple platforms**: build, run and test on iOS, watchOS, tvOS and visionOS simulators and devices
- **Hot reload**: `swx run --hot` reloads saved Swift files into the running app, SwiftUI state included, without touching the project
- **Editing dependencies**: `swx add` goes from a package name to a resolved dependency, like `uv add`; `remove` and `upgrade` too
- **Dependency graphs**: `swx graph` as a tree, Graphviz, Mermaid or JSON; `show-dependencies` without SwiftPM
- **Inspection**: `why`, `outdated`, `audit` (known vulnerabilities), `licenses`, and undeclared imports, with a policy file for CI
- **CI**: a GitHub Action, selective testing, `resolve --check`, and a remote cache (S3, HTTP or a directory) for checkouts and build outputs
- **Monorepos**: `--all` resolves, checks, builds, tests and caches every package of a repository
- **Publishing**: `swx publish` to an SE-0391 registry, signed, as `swift package-registry publish` does
- **Housekeeping**: `swx cache size` and `prune` for the store and remote caches, `swx self update`
- **Toolchains**: installs swift.org releases and snapshots, honours `.swift-version`
- **Tools and scripts**: runs package executables like `uvx`, and single-file scripts with dependencies
- **Verified**: every compatibility claim is checked against SwiftPM or Xcode in CI

To learn more, read the [user guide](https://swx.quadratic.xyz/guide.html).

## swx in action

```sh
swx add swift-argument-parser            # find it, pick the newest release, add it, resolve
swx upgrade                              # move requirements that exclude the newest releases
swx package resolve                      # same Package.resolved as `swift package resolve`
swx build -c release                     # resolves, then SwiftPM builds with resolution disabled
swx graph                                # targets and the products they use, as a tree
swx audit                                # known vulnerabilities in your pins
swx test --selective                     # only test targets whose inputs changed
swx cache pull --build                   # checkouts and .build from a remote cache (CI)
swx package resolve --all                # every package of a monorepo, one store
swx publish mona.LinkedList 1.2.0        # to a registry, as swift package-registry publish
swx cache prune --older-than 30d         # what no project pins and nothing used lately
swx run --platform ios HelloApp          # build, install and launch on a simulator
swx run --hot --platform ios HelloApp    # …and reload each saved file in the running app
swx xcode resolve --source-packages SourcePackages
swx toolchain install 6.4
swx tool run swiftformat@0.54.0 --version
swx run greet.swift Ada                  # a script with dependencies in a comment
```

Anything swx doesn't handle is forwarded to `swift package`.

## Performance

Vapor + Fluent (32 packages) on Apple Silicon with Swift 6.4, both tools starting from empty
caches. Cold resolves depend most on the network, so that row is the median of three runs. Every
run produced byte-identical `Package.resolved` and `workspace-state.json`.

| Scenario | SwiftPM | swx | Speedup |
|---|---|---|---|
| Cold resolve | 72.5 s | 17.3 s | 4× |
| No lockfile, warm cache | 13.4 s | 1.6 s | 8× |
| Fresh clone (lockfile, no `.build`) | 1.5 s | 0.10 s | 15× |
| No-op | 0.26 s | 0.02 s | 13× |

`Scripts/benchmark.py` reproduces these runs. See [how it is fast](https://swx.quadratic.xyz/#speed).

## Installation

```sh
curl -fsSL https://swx.quadratic.xyz/install.sh | sh
```

This installs the release for your OS and CPU (macOS universal, or a static Linux binary for
x86_64 or aarch64) into `~/.local/bin`, after checking it against the release's `SHA256SUMS`.
`swx self update` later replaces it with the newest release, checked the same way.

With Homebrew (the repository is its own tap), or with [Mint](https://github.com/yonaskolb/Mint):

```sh
brew tap jeslyvarghese/swx https://github.com/jeslyvarghese/swx && brew install swx
mint install jeslyvarghese/swx
```

<details>
<summary>Build swx from source</summary>

With Swift 6.1 or later:

```sh
git clone https://github.com/jeslyvarghese/swx && cd swx
swift build -c release
cp .build/release/swx ~/.local/bin/
ln -s swx ~/.local/bin/swift-x   # optional: enables `swift x …`
```

`Scripts/build-linux-static.sh` builds a fully static musl binary for Linux.

</details>

## Contributing

Found a difference from SwiftPM? That's a bug: please
[open an issue](https://github.com/jeslyvarghese/swx/issues/new/choose). To work on swx, read the
[contributing guide](CONTRIBUTING.md), which covers the architecture and the differential checks.

## License

Apache License v2.0 with Runtime Library Exception, the same license as the Swift Package
Manager, from which parts of swx are adapted. See [LICENSE.txt](LICENSE.txt) and
[NOTICE.txt](NOTICE.txt).
