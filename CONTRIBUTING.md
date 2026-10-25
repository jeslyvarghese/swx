# Contributing to swx

Thanks for helping. swx's one promise is that it is **indistinguishable from SwiftPM and Xcode in
the files it writes**, so most contributions come with a differential check.

## Building and testing

```sh
swift build
swift test
```

Before sending a change that touches resolution, checkouts or file formats, run the matching
differential scripts against SwiftPM (they are listed under *Verification* in the README), for
example:

```sh
swift build -c release
Scripts/compare-with-swiftpm.sh Tests/Fixtures/sample .build/release/swx
```

Manifest parser changes must keep `swx debug manifest-parity` at 0 mismatches on the corpus
(`Scripts/build-corpus.sh <cache-dir>`, then `swx debug manifest-parity --cache-path <cache-dir>`).

## Reporting a difference from SwiftPM

If swx writes a different `Package.resolved`, `workspace-state.json` or checkout than SwiftPM,
that is a bug. Open an issue with the `Package.swift` (or a public package) and both files.

## Code style

- No magic numbers or strings: use a constant or an enum.
- Early returns and `continue` instead of nested conditionals.
- Enums instead of `Bool` parameters.
- Respect the layering in the README's *Architecture* section: `SwxCLI` only talks to
  `SwxWorkspace`; only `SwxSource` touches the network and git; only `SwxStore` knows the cache
  layout.
- Separate logical blocks with a blank line and a short comment saying what the block does and why.

## License

By contributing, you agree that your contributions are licensed under the project's license,
the Apache License v2.0 with Runtime Library Exception (see `LICENSE.txt`).
