---
name: swx
description: Build, test and run Swift packages and Apple apps (iOS, tvOS, watchOS, visionOS, macOS) with swx, and iterate on app UI with hot reload and screenshots. Use whenever a task involves Package.swift, swift build/test/run, xcodebuild, a simulator, or checking what a SwiftUI/UIKit change looks like.
---

# Swift work with swx

swx replaces `swift build|test|run|package` and xcodebuild for Apple apps. It reads and writes
the same files as SwiftPM and Xcode, so nothing in the project changes. Prefer it (or the
`swx_*` MCP tools) over `swift` and `xcodebuild`: its reports are short and structured.

## Always

- Pass `--format json`: stdout is one JSON object, progress is on stderr.
- Exit code 0 is success, 1 failure, 64 bad arguments.
- An error is `{"status":"error","error":{"code","message","fix"}}`; do what `fix` says.
- Reports name the full log (`log`); read it only when the summary isn't enough.

## Packages

```sh
swx build --format json          # diagnostics: severity, file, line, column, message
swx test --format json           # tests: passed, failed, skipped, failures with file/line/message
swx test --format json --filter MySuite
swx run --format json --timeout 30 <executable> [args]   # the program's output
swx add <url|owner/repo|name>[@version] --format json    # add a dependency, then resolve
swx resolve --format json
```

## Apple apps

```sh
swx devices --format json
swx build --platform ios --format json
swx test --platform ios --format json
```

Use hot reload to work on an app's UI. It runs in the background:

```sh
swx hot start --platform ios <App> --format json   # returns once the app runs; build errors otherwise
# edit and save Swift files
swx hot status --wait --format json   # what each save did
swx screenshot --format json          # PNG path; open it to check the UI
swx hot logs --lines 50               # the app's console
swx hot stop                          # when done
```

After each round of edits, run `swx hot status --wait` and read the newest events:

- `reloaded`: the app runs the new code and keeps its state. Take a screenshot to check it.
- `not-reloaded`: compile error. Fix the `diagnostics` and save again.
- `relaunching`: the edit changed a type's stored properties, so swx rebuilt and relaunched.
- `build-failed`: fix the `diagnostics`; swx builds again on the next save.

Stop the session with `swx hot stop` when the task is done.
