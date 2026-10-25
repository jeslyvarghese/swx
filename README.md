# swx

A fast, drop-in companion to SwiftPM: what `uv` is to `pip`.

`swx` reads and writes SwiftPM's own files (`Package.swift`, `Package.resolved`,
`.build/workspace-state.json`, `.build/checkouts`, Xcode's `SourcePackages`) **byte for byte**, so
a team can mix `swx`, `swift` and Xcode freely. There is nothing to migrate.

It also covers the jobs of several other tools:

| Job | Usually done with | swx |
|---|---|---|
| Resolve and update dependencies | `swift package resolve/update` | `swx package resolve/update` |
| Build, test, run | `swift build/test/run` | `swx build/test/run` (resolves first, much faster) |
| Xcode project dependencies | Xcode, `xcodebuild -resolvePackageDependencies` | `swx xcode resolve` |
| Toolchains | swiftly | `swx toolchain …`, `.swift-version` |
| CLI tools from packages | Mint | `swx tool run swiftformat@0.54.0` |
| Single-file scripts with dependencies | (none) | `swx run script.swift` |
| iOS/watchOS/tvOS/visionOS builds and runs | Xcode, `xcodebuild` + `simctl` | `swx build/run/test --platform ios` |

## Install

```sh
swift build -c release
cp .build/release/swx /usr/local/bin/
ln -s /usr/local/bin/swx /usr/local/bin/swift-x   # optional: enables `swift x …`
```

## Usage

```sh
# Dependencies (drop-in for swift package resolve/update; same flags)
swx package resolve
swx package update
swx package show-dependencies          # any other subcommand is forwarded to `swift package`

# Build, test, run: swx resolves, then SwiftPM builds with resolution disabled
swx build -c release
swx test
swx run MyTool --flag

# Apple platforms (xcodebuild + simctl/devicectl underneath)
swx devices                                        # simulators and paired devices
swx build --platform ios                           # generic build when no simulator exists
swx run   --platform ios HelloApp                  # build, install, launch, stream console
swx run   --platform ios --destination device --team ABCDE12345 HelloApp
swx test  --platform watchos                       # package tests on a watchOS simulator

# Xcode projects
swx xcode generate                 # an .xcodeproj for the package's .iOSApplication products (via XcodeGen)
swx xcode resolve --source-packages SourcePackages
xcodebuild -clonedSourcePackagesDirPath SourcePackages -disableAutomaticPackageResolution \
           -onlyUsePackageVersionsFromResolvedFile …

# Toolchains (.swift-version is honoured by every command, and installed on demand)
swx toolchain list --available
swx toolchain install 6.4
swx toolchain install main-snapshot   # also 6.5-snapshot, main-snapshot-2026-10-17, or a snapshot tag
swx toolchain use 6.4          # writes .swift-version
swx toolchain which

# Tools (like uvx / Mint): cached per revision and toolchain
swx tool run swiftformat@0.54.0 --version
swx tool run realm/SwiftLint lint
swx tool install swiftlint     # links into ~/.local/bin

# Scripts with inline dependencies
swx run greet.swift Ada
```

A script declares its dependencies in a comment block. Products are inferred from the script's `import`s:

```swift
#!/usr/bin/env -S swx run
// swx-dependencies:
// .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")

import ArgumentParser
```

Environment variables:

| Variable | Effect |
|---|---|
| `SWX_CACHE_DIR` | Location of the shared store. Default: `~/.cache/swx`, or `$XDG_CACHE_HOME/swx`. |
| `SWX_HOME` | Toolchain location. Default: `~/.local/share/swx`. |
| `SWX_TRACE=1` | Prints a timestamped timeline of every subprocess. |
| `SWX_STATIC_MANIFESTS=0` | Always evaluates manifests with the compiler. |
| `SWX_GIT_HTTP=0` | Lists tags with `git ls-remote` instead of HTTP. |
| `SWX_BUILD_CACHE=0` | Disables the shared compilation cache. `=1` opts into it with SwiftPM's native build system. |

## Benchmarks

Measured on Apple Silicon, macOS 27, Swift 6.4, with both tools starting from empty caches.
Every run produced byte-identical `Package.resolved` and `workspace-state.json`.

**Vapor + Fluent (32 packages):**

| Scenario | SwiftPM | swx | Speedup |
|---|---|---|---|
| Cold (empty caches) | 77 s | 10.9 s | 7× |
| No lockfile, warm cache | 13.4 s | 1.6 s | 8× |
| `update`, warm cache | 8.8 s | 1.6 s | 5× |
| Fresh clone (lockfile, no `.build`) | 1.5 s | 0.10 s | 15× |
| No-op | 0.26 s | 0.02 s | 13× |

**swift-argument-parser + swift-nio** (`Tests/Fixtures/sample`, medians of 3, `python3 -I Scripts/benchmark.py Tests/Fixtures/sample`):

| Scenario | SwiftPM | swx | Speedup |
|---|---|---|---|
| Cold (empty caches) | 27.7 s | 7.3 s | 3.8× |
| No lockfile, warm cache | 2.44 s | 0.46 s | 5.3× |
| Fresh clone (lockfile, no `.build`) | 0.56 s | 0.03 s | 21× |
| No-op | 0.19 s | 0.02 s | 12× |

**Other measurements:**

| Measurement | Result |
|---|---|
| Warm script start (`swx run greet.swift`) | 10 ms |
| Pinned tool start (`swx tool run swiftformat@0.54.0`) | 20 ms |
| Xcode project resolve (2 packages) | 4.0 s with xcodebuild, 1.4 s with swx. Pins, `originHash` and `SourcePackages` state are identical. |
| lottie-spm (217 MB XCFramework), fresh clone with lockfile | 3.0 s with SwiftPM (unzips again per project), 0.01 s with swx |

## How it is fast

- **Blobless bare clones** in one global store.
  - Listing files at any tag is local.
  - All the manifests one resolution step needs arrive in a single batched fetch.
- **Tag listing over HTTP.** HTTPS remotes are asked for their tags with git's protocol v2 `ls-refs` directly, on connections reused across a host's repositories, instead of starting `git ls-remote` per package (falling back to it for SSH, credentials or older servers). With a warm store and no lockfile, Vapor's 32 packages resolve in 0.9 s instead of 1.6 s. `swx debug tag-parity <urls>` compares both listings.
- **Pipelined graph walk.** As soon as a manifest loads, `swx` lists its dependencies' tags and loads their likely manifests. The graph streams in instead of being explored one level at a time.
- **Speculative checkout export**, overlapped with resolution.
- **Copy-on-write checkouts.**
  - macOS uses APFS `clonefile`.
  - Linux uses `cp --reflink=auto`.
  - SwiftPM and Xcode accept these plain trees.
- **Static manifest parsing.** Declarative `Package.swift` files are read with SwiftParser, without compiling.
  - Evaluates `#if` for the host.
  - Replays `package.targets.append(…)` and appends to top-level `var`s.
  - Ignores code that only touches build settings.
  - Anything it can't prove harmless falls back to real evaluation.
  - On a 364-manifest corpus (114 popular packages and their dependencies), 74% parse statically with 0 disagreements against `dump-package`.
- **Shared binary artifacts.** Remote `binaryTarget` archives (and `.artifactbundleindex` files, resolved to the host's archive the way SwiftPM picks it) are downloaded once per checksum, verified, unzipped once into the store, and cloned into `.build/artifacts`. The downloads overlap with checkouts. SwiftPM finds them already recorded and doesn't fetch or unzip again.
- **Content-addressed caches.**
  - Evaluated manifests are keyed by text plus toolchain.
  - Manifest files are keyed by commit.
  - Toolchain identity is keyed by a stat fingerprint, so `swift --version` isn't re-spawned.
  - Built tools and scripts are keyed by content plus toolchain.
- **Lockfile fast paths.**
  - If the `originHash` matches and the checkouts match, `swx` does nothing.
  - If only the checkouts are missing, it restores them without running the solver.
  - Otherwise (a manifest edit, or a tools-5.9 lockfile without `originHash`), it first solves with only the pinned versions, like SwiftPM's precomputation. Tags are listed only if the pins no longer fit.

## Architecture

```
SwxCLI          argument parsing and output; talks only to SwxWorkspace
SwxWorkspace    orchestration: lockfiles, workspace state, resolution loop, mirrors,
                tools, scripts, toolchain selection, Apple builds
 ├─ SwxResolver    PubGrub as a pure, sans-I/O state machine (no Foundation)
 ├─ SwxManifest    manifest model, SwiftPM's pruning rules, static parser, evaluation, cache
 ├─ SwxBuild       BuildDriver: SwiftPM (host) and xcodebuild (Apple) backends
 ├─ SwxToolchain   swift.org releases, install, .swift-version, activation
 ├─ SwxXcode       .xcodeproj / .xcworkspace package references
 └─ SwxDevice      simctl / devicectl: the only module that launches apps
SwxSource       git: ls-remote, blobless clones, batched blob reads, tree export
SwxStore        global content-addressed store and checkout materialization
SwxApple        platforms and destinations (pure)
SwxSystem       subprocesses, file system, tracing
SwxCore         Version, ranges, identities, tools versions (no Foundation)
```

The design is **functional core, imperative shell**.

- **The solver never performs I/O.** It returns `.needs(required:prefetch:)`; the workspace fulfils the requests concurrently and resumes it.
- **The other pure parts:**
  - version-set algebra (bitsets over known versions)
  - manifest selection
  - dependency pruning
  - static manifest interpretation
  - lockfile encoding
- **They are unit-tested without network or fixtures.**

## Compatibility

These areas are verified byte for byte against SwiftPM or Xcode:

- **`Package.resolved`:** v2/v3 written, v1 read. `originHash` matches SwiftPM's and Xcode's computation.
- **`workspace-state.json`:** v7, including path dependencies, dependency names taken from each manifest, and binary artifacts (XCFrameworks and artifact bundles). Xcode's `SourcePackages` spelling (`/tmp`, not `/private/tmp`) is matched too. Entries `swx` doesn't manage (local artifacts, prebuilts, edited packages) are carried through untouched.
- **Branch, revision and path dependencies:** branch pins keep their commit unless you run `update`.
- **Dependency semantics:**
  - SwiftPM's dependency pruning (5.2+ product reachability, traits)
  - tag-to-version rules, including version-specific tags and manifests
  - pre-release range semantics
  - the PubGrub decision heuristics
- **Mirrors** (`.swiftpm/configuration/mirrors.json` and `~/.swiftpm`): `swx` fetches from the mirror and records the original in the lockfile.
- **Git submodules and Git LFS in dependencies,** like SwiftPM's checkouts:
  - submodules are checked out recursively (`update = none` is honoured), each from its own blobless store repository
  - LFS files are fetched once into the store and replaced in the tree (needs `git-lfs`, as SwiftPM does)
  - relative submodule URLs resolve against the package's URL, as git does; SwiftPM resolves them against its local cache, where they fail
- **Local git repositories** (`.package(url: "file:///…")` or an absolute path) are recorded as `localSourceControl`, by path, as SwiftPM does.
- **Package registries** (SE-0292, `.package(id: "scope.Name", …)`):
  - `registries.json` from `--config-path` (default `~/.swiftpm/configuration`) overlaid by the package's own, with scoped and default registries and availability checks
  - registry pins, `registryDownload` state, `.build/registry/downloads/<scope>/<name>/<version>` with `.registry-metadata`, and version-specific manifests advertised in `Link` headers
  - archives are verified against the release checksum and SwiftPM's trust-on-first-use fingerprints in `--security-path` (default `~/.swiftpm/security`), which `swx` reads and writes in SwiftPM's format
  - credentials as SwiftPM 6.4 finds them: `SWIFTPM_REGISTRY_TOKEN`/`_LOGIN`/`_PASSWORD`, `SWIFTPM_NETRC_DATA`, then the Keychain on macOS (`.netrc` with `--netrc`) or `.netrc` on Linux (`--netrc-file`), sent as basic or bearer auth per `registries.json`
  - releases are immutable, so metadata and manifests are cached in the store and a lockfile restore downloads only the archives
  - signatures (SE-0391): CMS signatures of archives and manifests are verified against Apple's roots and `trustedRootCertificatesPath`, with SwiftPM's code-signing policy, `onUnsigned`/`onUntrustedCertificate` actions, optional expiry and OCSP checks, default/registry/scope/package overrides, and signer trust on first use in `<security>/signing-entities` (for Apple-issued signers, as SwiftPM records). Compared with SwiftPM for untrusted, trusted, refused and tampered signatures
  - `--use-registry-identity-for-scm` and `--replace-scm-with-registry`: git dependencies the default registry maps (`/identifiers`) are renamed to, or replaced by, their registry packages, with `originalLocation`/`scmUrl` recorded as SwiftPM does
- **HTTPS git with `.netrc`** works through git itself, which reads `~/.netrc`.
- **Git tag fingerprints:** like SwiftPM's `checkIntegrity`, the commit behind each checked-out tag is recorded in `<security>/fingerprints/<identity>-<hash>.json` (the same files SwiftPM writes), and a tag that later moves is refused.
- **swift-syntax prebuilts:** SwiftPM still applies them after `swx` resolves. A macro build took 3.5 s of CPU instead of 55 s.
- **Xcode configuration:** `registries.json` and `mirrors.json` are read from the workspace's `xcshareddata/swiftpm/configuration`, where Xcode keeps them; registry packages in projects resolve exactly as xcodebuild does.
- **Mixed use:**
  - `swift package update` works on top of `swx` checkouts.
  - `xcodebuild` builds offline from `swx`-prepared `SourcePackages`.

## Verification

```sh
swift test                                            # 113 unit tests
Scripts/compare-with-swiftpm.sh <package-dir>         # differential resolve against SwiftPM
Scripts/compare-pin-reuse.sh                          # lockfile reuse vs SwiftPM: pins kept, new deps, changed requirements
Scripts/compare-submodules.sh                         # nested submodules vs SwiftPM, compared file by file
Scripts/linux/lfs-check.sh                            # Git LFS dependencies vs SwiftPM (in a Linux Swift image)
Scripts/compare-registry.sh                           # registries vs SwiftPM, via Scripts/test-registry.py (open and basic auth)
Scripts/compare-registry-signing.sh                   # signed releases vs SwiftPM: trusted, untrusted, refused, tampered
Scripts/compare-fingerprints.sh                       # git tag fingerprints vs SwiftPM, and a moved tag refused by both
Scripts/compare-apple-manifest.sh                     # a dynamic AppleProductTypes app vs xcodebuild (macOS with Xcode)
Scripts/compare-xcode-apps.sh                         # iOS app + widget + watch app project: resolution vs xcodebuild, build, launch
Scripts/compare-xcode-registry.sh                     # registry packages in an Xcode project vs xcodebuild
Scripts/check-xcode-generate.sh                       # swx xcode generate: generate, resolve with swx, build offline, check Info.plist
Scripts/check-apple-platforms.sh                      # device builds and simulator tests on iOS, watchOS, tvOS, visionOS
swx debug manifest-parity --candidate xcode …         # Xcode ManifestAPI evaluation vs dump-package on the corpus
Scripts/build-corpus.sh <cache-dir>                   # resolve Corpus/packages.txt into a cache…
swx debug manifest-parity --cache-path <cache-dir>    # …then check the static parser against dump-package
```

## Linux

`Scripts/build-linux-static.sh` builds a fully static musl binary: 64 MB stripped, with no runtime dependencies. It runs in a bare Alpine image. Downloads go through URLSession (statically linked libcurl), because the official Swift images ship no `curl` executable.

`Scripts/linux/run-in-container.sh` runs the Linux workflow in the official `swift:6.4.1-noble` image with Apple's `container` CLI or Docker. On that image:
- `Package.resolved` and `workspace-state.json` are identical to Linux SwiftPM's
- a cold resolve takes 4.5 s vs SwiftPM's 20.5 s, and a no-op takes 8 ms
- `swx run`, scripts and tools all work
- binary artifacts match SwiftPM's entries, and a second project reuses the store
- checkouts use `cp --reflink=auto`

CI (`.github/workflows/ci.yml`) runs the unit tests and differential checks on macOS and Linux, and builds the static binary.

## Deviations from the original plan

- **Apple platforms and swift-build.** The plan was to link swift-build in-process and write a PIF builder. Instead, `swx` drives swift-build through `xcodebuild`, which embeds the same engine:
  - PIF and the build-service API are internal and unstable.
  - `xcodebuild` already supports `AppleProductTypes` apps, signing (`-allowProvisioningUpdates`) and every destination.
  - Host builds go through SwiftPM, which also runs swift-build.
- **`AppleProductTypes` manifests** that the static parser declines are compiled against Xcode's ManifestAPI (which ships `AppleProductTypes`), run in SwiftPM's sandbox, and decoded from PackageDescription's own serialization; the command-line SwiftPM can't import that module at all. This needs Xcode. Over the 364-manifest corpus, that path agrees with `dump-package` on every manifest both can evaluate (`swx debug manifest-parity --candidate xcode`).
- **The shared compilation cache** uses SwiftPM's `--enable-build-caching` where a toolchain has it (none does yet, 6.5 snapshots included). Otherwise it uses the compiler's own CAS (`-cache-compile-job`, with each package root mapped to one prefix, so dependencies compiled in one project hit in another). That works only under SwiftPM's native build system, which 6.4 marks deprecated, so it turns on when you pass `--build-system native`, or with `SWX_BUILD_CACHE=1`, which also selects it. Measured on swift-collections (release): 6.4 s for the first project, 1.7 s for the second.
- **No long-lived `git cat-file` per repository.** A cold Vapor resolve spends 1.5 s of cumulative (parallel) time in its 128 `cat-file` calls, against 57 s in network-bound tree exports, and a warm resolve without a lockfile starts one process in total. One batched `cat-file` per step stays.
- **Manifest evaluation** (for manifests the static parser declines) compiles the manifest against the toolchain's ManifestAPI and decodes PackageDescription's serialization, as SwiftPM's loader does internally, instead of starting `swift package dump-package`: about a third faster per cold manifest, and identical on 362 of the 364 corpus manifests; the other 2 fail under `dump-package` too (`swx debug manifest-parity --candidate toolchain`). The static parser handles 267 of them identically and declines the rest, with no mismatches. `dump-package` remains the fallback.

## Not yet supported

- **Multi-root workspaces.**

## License

Apache License v2.0 with Runtime Library Exception, the same license as the Swift Package Manager, from which parts of swx are adapted. See [LICENSE.txt](LICENSE.txt) and [NOTICE.txt](NOTICE.txt).
