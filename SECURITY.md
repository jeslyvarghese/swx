# Security policy

swx downloads and runs code: it fetches packages, verifies registry signatures (SE-0391) and
git tag fingerprints, extracts archives and binary artifacts, and evaluates `Package.swift`
manifests in a sandbox on macOS. A bug in any of these can be a security issue.

## Reporting a vulnerability

Please report it privately through
[GitHub's private vulnerability reporting](https://github.com/jeslyvarghese/swx/security/advisories/new),
not in a public issue. Include the swx version (`swx --version`), your OS, and the steps or a
package that reproduces it.

You can expect an acknowledgement within a week. Fixes are released as a new version, and the
advisory is published once a fixed release is available.

## Supported versions

Only the latest release receives security fixes.

## Scope

Particularly in scope:

- accepting a package, archive or binary artifact whose checksum, signature or fingerprint
  SwiftPM would refuse
- writing outside the store, `.build` or `SourcePackages` (path traversal in archives)
- a manifest escaping the evaluation sandbox where SwiftPM's would not
- leaking registry credentials (`.netrc`, Keychain) to another host

Behaviour that matches SwiftPM's (for example, trust on first use for fingerprints) is by design;
report those upstream to the [Swift Package Manager](https://github.com/swiftlang/swift-package-manager).
