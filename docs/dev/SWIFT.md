# Swift

Package tools: Swift 6.3. Language mode 6. macOS 26, Apple Silicon only.

Pin: `.swift-version` (`6.3.3`). This machine’s `/usr/bin/swift` may still be Xcode 6.2. Put `~/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin` on `PATH` first, or run `swiftly run 6.3.3 -- swift test`.

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
