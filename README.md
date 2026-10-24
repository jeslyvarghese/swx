# swx

A fast, drop-in companion to SwiftPM: what `uv` is to `pip`.

`swx` reads and writes SwiftPM's own files (`Package.swift`, `Package.resolved`,
`.build/workspace-state.json`, `.build/checkouts`), byte for byte, so a team can mix
`swx` and `swift` freely. There is nothing to migrate.

**Status: milestone 1 (drop-in resolver).** `swx package resolve` and `swx package update` work
end to end. Building still goes through `swift build`, which finds everything already resolved.

## Usage

```sh
swift build -c release
.build/release/swx package resolve      # like `swift package resolve`
.build/release/swx package update       # like `swift package update`
swift build                             # SwiftPM sees the dependencies as resolved; no network work

# Optional: let SwiftPM discover it as `swift x …`
ln -s "$PWD/.build/release/swx" /usr/local/bin/swift-x
swift x package resolve
```

Options follow SwiftPM's spelling: `--package-path`, `--cache-path`, `-j`, `-v`, `-q`.
Set `SWX_TRACE=1` to get a timestamped timeline of every subprocess.

## Benchmarks

Measured on Apple Silicon, macOS, Swift 6.4, both tools starting from empty caches.

**Vapor + Fluent (32 packages):**

| Scenario                        | SwiftPM | swx    | Speedup |
|---------------------------------|---------|--------|---------|
| Cold (empty caches)             | 77 s    | 11.5 s | 6.7×    |
| No lockfile, warm cache         | 13.4 s  | 1.6 s  | 8.3×    |
| `update`, warm cache            | 8.8 s   | 1.6 s  | 5.4×    |
| Fresh clone (lockfile, no `.build`) | 1.5 s | 0.10 s | 15×   |
| No-op                           | 0.26 s  | 0.02 s | 13×     |

**swift-argument-parser + swift-nio (5 packages):** cold 28.8 s → 8.6 s. Every run produced a
byte-identical `Package.resolved` and `workspace-state.json`.

## How it is fast

Each item is a design choice, not a micro-optimization:

- **Blobless bare clones** (`--filter=blob:none`) in one global store. Listing files at any tag is
  local; file contents are downloaded only when needed.
- **Batched blob fetches.** All the manifests a resolution step needs come down in a single round trip.
- **Pipelined graph walk.** As soon as any manifest loads, `swx` starts listing tags for its
  dependencies and loading the manifest of each one's likely version. The graph streams in
  instead of being explored one level at a time.
- **Speculative checkout export.** A version's source tree starts exporting as soon as the solver
  considers that version.
- **Copy-on-write checkouts.** Trees are exported once per commit into the store and cloned into
  each project with APFS `clonefile`, instantly and with no extra disk space. SwiftPM accepts these
  plain trees.
- **Content-addressed caches.**
  - Evaluated manifests are keyed by manifest text plus toolchain.
  - Manifest files are keyed by commit SHA.
  - Both caches are correct by construction: a cached result is a memoized pure function of its key.
- **Lockfile fast paths.**
  - If `Package.resolved` was produced from the current manifest (`originHash`) and the checkouts
    match, `swx` does nothing (about 15 ms).
  - If only the checkouts are missing, it restores them from the store without running the solver.

## Architecture

```
SwxCLI         argument parsing and output; talks only to SwxWorkspace
SwxWorkspace   orchestration: Package.resolved, workspace-state.json, the resolution loop
 ├─ SwxResolver   PubGrub as a pure, sans-I/O state machine (no Foundation)
 ├─ SwxManifest   manifest model, SwiftPM's dependency-pruning rules, evaluation and cache
 └─ SwxSource     git: ls-remote, blobless clones, batched blob reads, tree export
SwxStore       global content-addressed cache and checkout materialization
SwxSystem      subprocesses, file system, tracing
SwxCore        shared value types: Version, ranges, identities, tools versions (no Foundation)
```

**Functional core, imperative shell.** The solver never performs I/O. It returns
`.needs(required:prefetch:)`; the workspace fulfils the requests concurrently and calls `resume()`.
The pure parts include:

- version-set algebra, using bitsets over each package's known versions
- manifest selection
- dependency pruning
- lockfile encoding

The pure parts are unit-tested without network or fixtures.

### SwiftPM semantics reproduced

- Package identity, case-preserving names, and checkout subpaths.
- Version-specific manifests (`Package@swift-X.swift`) and version-specific tags.
- SwiftPM's tag-to-version rules.
- Pre-release semantics of version ranges (`2.0.0-beta ∉ 1.0.0..<2.0.0`).
- Dependency pruning: roots keep everything; for 5.2+ dependencies, only what their products'
  targets use. This includes plugins and trait-guarded dependencies.
- PubGrub decision heuristics:
  - release-only terms first
  - then the term with the fewest matching versions
  - pinned version preferred, else the highest
- Branch, revision and path dependencies at the root, which are fixed outside the solver.
  Branch pins keep their commit unless you run `update`.
- `Package.resolved` v1 (read), v2 and v3 (write), with `originHash` = SHA-256 of the root manifest.

## Verification

```sh
swift test                                            # unit tests (33)
Scripts/compare-with-swiftpm.sh <package-dir>         # differential run against SwiftPM
```

The differential script resolves a package with both tools from empty caches. It diffs both files
and checks that `swift package resolve` accepts `swx`'s checkouts without re-resolving.

## Not yet supported

- Registry dependencies (SE-0292), mirrors, and `.netrc` auth for HTTPS.
- Git submodules inside dependencies.
- Edited dependencies (`swift package edit`), and multi-root workspaces.
- Static manifest parsing (milestone 2). Today every new manifest is evaluated once with
  `swift package dump-package`, then cached forever.
- `build`, `test` and `run` pass-through, toolchains, tools and scripts (milestones 3–6, see the plan).
- Linux copy-on-write (`FICLONE`): Linux currently falls back to a plain copy.
