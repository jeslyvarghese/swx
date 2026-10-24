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
swx xcode resolve --source-packages SourcePackages
xcodebuild -clonedSourcePackagesDirPath SourcePackages -disableAutomaticPackageResolution \
           -onlyUsePackageVersionsFromResolvedFile …

# Toolchains (.swift-version is honoured by every command, and installed on demand)
swx toolchain list --available
swx toolchain install 6.4
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
| `SWX_BUILD_CACHE=0` | Disables the shared compilation cache. |

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

**Other measurements:**

| Measurement | Result |
|---|---|
| swift-argument-parser + swift-nio, cold resolve | 28.8 s with SwiftPM, 8.6 s with swx |
| Warm script start (`swx run greet.swift`) | 10 ms |
| Pinned tool start (`swx tool run swiftformat@0.54.0`) | 20 ms |
| Xcode project resolve (2 packages) | 4.0 s with xcodebuild, 1.4 s with swx. Pins, `originHash` and `SourcePackages` state are identical. |

## How it is fast

- **Blobless bare clones** in one global store.
  - Listing files at any tag is local.
  - All the manifests one resolution step needs arrive in a single batched fetch.
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
  - On a 90-manifest corpus of popular packages, 74% parse statically with 0 disagreements against `dump-package`.
- **Content-addressed caches.**
  - Evaluated manifests are keyed by text plus toolchain.
  - Manifest files are keyed by commit.
  - Toolchain identity is keyed by a stat fingerprint, so `swift --version` isn't re-spawned.
  - Built tools and scripts are keyed by content plus toolchain.
- **Lockfile fast paths.**
  - If the `originHash` matches and the checkouts match, `swx` does nothing.
  - If only the checkouts are missing, it restores them without running the solver.

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
- **`workspace-state.json`:** v7, including path dependencies and SwiftPM's own artifacts and prebuilts, which are carried through untouched.
- **Branch, revision and path dependencies:** branch pins keep their commit unless you run `update`.
- **Dependency semantics:**
  - SwiftPM's dependency pruning (5.2+ product reachability, traits)
  - tag-to-version rules, including version-specific tags and manifests
  - pre-release range semantics
  - the PubGrub decision heuristics
- **Mirrors** (`.swiftpm/configuration/mirrors.json` and `~/.swiftpm`): `swx` fetches from the mirror and records the original in the lockfile.
- **swift-syntax prebuilts:** SwiftPM still applies them after `swx` resolves. A macro build took 3.5 s of CPU instead of 55 s.
- **Mixed use:**
  - `swift package update` works on top of `swx` checkouts.
  - `xcodebuild` builds offline from `swx`-prepared `SourcePackages`.

## Verification

```sh
swift test                                            # 62 unit tests
Scripts/compare-with-swiftpm.sh <package-dir>         # differential resolve against SwiftPM
Scripts/build-corpus.sh <cache-dir>                   # resolve Corpus/packages.txt into a cache…
swx debug manifest-parity --cache-path <cache-dir>    # …then check the static parser against dump-package
```

## Deviations from the original plan

- **Apple platforms and swift-build.** The plan was to link swift-build in-process and write a PIF builder. Instead, `swx` drives swift-build through `xcodebuild`, which embeds the same engine:
  - PIF and the build-service API are internal and unstable.
  - `xcodebuild` already supports `AppleProductTypes` apps, signing (`-allowProvisioningUpdates`) and every destination.
  - Host builds go through SwiftPM, which also runs swift-build.
- **`AppleProductTypes` manifests** can only be read by the static parser. The command-line SwiftPM can't import that module, so dynamic app manifests aren't supported.
- **The shared compilation cache** (`--enable-build-caching --build-cache-path <store>/cas`) turns on automatically only with toolchains whose SwiftPM has those flags. Swift 6.4 and 6.4.1 don't, so on them `swx` relies on SwiftPM's prebuilts and incremental builds.
- **Manifest evaluation** still shells out to `swift package dump-package`, and only for manifests the static parser declines.

## Not yet supported

- **Package registries** (SE-0292), and `.netrc` auth for HTTPS git.
- **Git submodules inside dependencies.**
- **`swift package edit`.** It is forwarded to SwiftPM, but checkouts are plain trees, so SwiftPM re-clones.
- **Multi-root workspaces.**
- **On Linux:** runtime is untested. `Scripts/build-linux-static.sh` cross-compiles a fully static musl binary, which shows all Linux code paths compile, but it has not been run on a Linux host.
