# SwiftTerm library runtime used by MyTerm

- Upstream: https://github.com/migueldeicaza/SwiftTerm
- Revision: `3219b171cacbe011635f1c1b6c47b0725ff56d3a`
- License: MIT; original `LICENSE` retained and copied into MyTerm App resources.
- Imported verbatim: `Sources/SwiftTerm/` and `LICENSE` from this revision, except for the two renderer files below.
- `Package.swift` is a MyTerm-owned library-only macOS manifest. Upstream examples, CLI tools, benchmarks, tests and their CLI/documentation plugin dependencies are not included. The runtime source, Metal shader resource, module and bundle names remain unchanged.

## Local delta

1. `Sources/SwiftTerm/Mac/MacTerminalView.swift`: optional `displayForegroundTransform` and `displayLineHighlight` callbacks; changing either invalidates the existing renderer caches. Both default to nil.
2. `Sources/SwiftTerm/Apple/AppleTerminalView.swift`: call the foreground transform before caching attributes; call the line callback once per line build, apply a single column range, and flush batches when entering/leaving the range. Existing selection colors win. These hooks are macOS-only and do not mutate parser, buffer, transport, glyph geometry or input handling.

The application owns all matching, accessibility contrast and color rules in `TerminalMessageHighlight.swift`. No logging, network requests or buffer storage is added by the hooks. Current MyTerm uses the existing renderer; changing rendering backends is outside this patch.

## Upgrade / reproducibility

A clean MyTerm checkout builds this local package directly, without downloading a fork or patching SwiftPM caches. All builds, including Dev and release, consume the same tracked vendor source. `Package.resolved` locks the remaining remote dependencies, not this directory.

Before updating: obtain a clean upstream checkout at the recorded revision and run `bash scripts/verify-swiftterm-vendor.sh /path/to/upstream-checkout` from MyTerm. This verifies the complete imported file list, every unmodified file, the license, and presents the two permitted renderer diffs. Preserve/review these minimal changes when importing a new upstream version, update this revision record and verifier, and run MyTerm's complete tests plus a clean scratch build and packaged resource checks. Never update only `.build/checkouts`.

The project tests include real renderer attribute/line construction tests (using `@testable import` on the debug dependency), input state/font regressions, and a bounded line-build benchmark. UI acceptance remains necessary for selection, theme switching, scrolling and TUI behavior.
