# Contributing to swx

Thanks for helping. swx's one promise is that it is **indistinguishable from SwiftPM and Xcode in
the files it writes**, so most contributions come with a differential check.

## Building and testing

```sh
swift build
swift test
```

Before sending a change that touches resolution, checkouts or file formats, run the matching
differential scripts against SwiftPM (listed under [Verification](#verification)), for example:

```sh
swift build -c release
Scripts/compare-with-swiftpm.sh Tests/Fixtures/sample .build/release/swx
```

Manifest parser changes must keep `swx debug manifest-parity` at 0 mismatches on the corpus
(`Scripts/build-corpus.sh <cache-dir>`, then `swx debug manifest-parity --cache-path <cache-dir>`).

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

## Verification

```sh
swift test                                            # 196 unit tests
Scripts/compare-with-swiftpm.sh <package-dir>         # differential resolve against SwiftPM
Scripts/compare-graph.sh                              # show-dependencies vs SwiftPM in every format; swx graph renders
Scripts/compare-lock-check.sh                         # resolve --check and resolve vs SwiftPM, lockfiles v2 and v3
Scripts/compare-local-artifacts.sh                    # local XCFrameworks and zips vs SwiftPM: state and extracted files
Scripts/check-remote-cache.sh                         # swx cache push/pull through a directory and an HTTP server, and --build
Scripts/check-manifest-edits.sh                       # add, remove and upgrade, each resolved like SwiftPM
Scripts/check-cache-prune.sh [swx] --self-update      # cache size/prune (store and remote), self update
Scripts/check-monorepo.sh                             # --all on a monorepo: each package vs SwiftPM, check, build, test, cache
Scripts/compare-registry-publish.sh                   # swx publish vs swift package-registry publish: archive, signatures, request
Scripts/compare-corpus.sh <work-dir> [swx] [first] [last]  # every Corpus/packages.txt entry resolved by SwiftPM and swx
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

## Reporting a difference from SwiftPM

If swx writes a different `Package.resolved`, `workspace-state.json` or checkout than SwiftPM,
that is a bug. Open an issue with the `Package.swift` (or a public package) and both files.

## Code style

- No magic numbers or strings: use a constant or an enum.
- Early returns and `continue` instead of nested conditionals.
- Enums instead of `Bool` parameters.
- Respect the layering described under [Architecture](#architecture): `SwxCLI` only talks to
  `SwxWorkspace`; only `SwxSource` touches the network and git; only `SwxStore` knows the cache
  layout.
- Separate logical blocks with a blank line and a short comment saying what the block does and why.

## License

By contributing, you agree that your contributions are licensed under the project's license,
the Apache License v2.0 with Runtime Library Exception (see `LICENSE.txt`).
