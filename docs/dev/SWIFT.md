# Swift

Package tools: Swift 6.3. Language mode 6. macOS 26, Apple Silicon only.

Pin: `.swift-version` (`6.3.3`). This machine’s `/usr/bin/swift` may still be Xcode 6.2. Prefer `tools/swift-6.3.3` (or put `~/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin` on `PATH` first). `swiftly run 6.3.3 -- swift test` also works if proven.

## Compile times

Standalone 6.3.3 has no `prebuilt-modules`. SPM builds Darwin/Foundation overlays into `.build/arm64-apple-macosx/debug/ModuleCache` (~80 MB). `rm -rf .build` and `swift package clean` wipe that cache.

Measured on this M3 Max / macOS 26 / SDK 26.2 (2026-08-18):

| Action | Typical |
|---|---|
| Clean `swift build` (debug) | ~12s |
| Clean `swift test` | ~16s |
| Incremental no-op | ~0.2s compile |
| Engine file edit + `--filter RVEngineTests` | <1s |
| `import Foundation` typecheck, cold cache | ~8s |
| Same, warm cache | ~0.1s |

Slowest Engine body (`tokenizeCommand`) is ~22 ms. Do not merge modules or rewrite Normalize to “fix” clean builds.

Gate: keep `.build` warm. Prefer `tools/gate.sh <Target>Tests` (or `tools/swift-6.3.3 test --filter <Target>Tests`). A 10s+ clean is ModuleCache unless `-debug-time-function-bodies` shows a hot function.

T2 ArgumentParser is the next real compile bill. Domain public-API edits today rebuild only Engine + Packs (the libraries that `import RVDomain`); filled stubs will fan out.

## Style contract

- Value types only in Domain/Engine/Packs/Presentation. `class` only at XPC/`NSObject` `RVService` edge.
- Newtypes: `PackID`, `RuleID`, `ShellCommand`. Closed `Decision` enum. No boolean `isDenied`.
- Small capability protocols (`PatternEngine`, `HostCodec`, `FrameRenderer`). Prefer `some`; `any` only for mixed lists.
- Functional core / imperative shell. Pure `evaluate` (no `Date()` / `FileManager` / `ProcessInfo`).
- Typed errors. `Sendable` + actors for stores. No `try!` / `!` on production paths.
- TUI: `reduce` + `render` → `[String]`.

## Layout

- Sources live under `Sources/<Module>/`.
- Tests live under `Tests/<Module>Tests/`.
- Tests use Swift Testing (`import Testing`). No XCTest.
- Public surface stays small. Internals are `package` later.
- No `try!` / IUO on production paths.

## Release artifacts

Measured on this machine 2026-08-21 after `tools/release.sh`. C `rv` is `clang -Os` + `strip -x` (links libSystem only). Swift `rv-cli` is SPM product `rv` after `strip -x`; `rvd` is the same. Pack bundles must travel with `rv-cli` and `rvd`: SPM `Bundle.module` loads `rv_RVPacks.bundle` next to those binaries. Code-sign is not a gate (`strip -x` invalidates an existing signature).

| Artifact | Size |
|---|---|
| staged `rv` | 36 KB (36,976 bytes), C hook |
| staged `rv-cli` | 2.3 MB (2,381,792 bytes), SPM product `rv` |
| staged `rvd` | 886 KB (907,088 bytes) |
| `rv_RVPacks.bundle` | 1.0 MB (100 files under `packs/`) |
