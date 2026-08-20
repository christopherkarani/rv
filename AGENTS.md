# AGENTS.md — rv

Work only in `~/CodingProjects/rv`. Do not implement in sibling repos. Do not write foreign product names into this tree.

v1 platform: macOS 26, Apple Silicon only. Package tools Swift 6.3. Language mode 6.

Hexagonal modules; dependency arrows down; a test that needs a TTY to prove a **decision** is in the wrong module.

Ticket order T0→T1 then PLAN’s parallel rules. T0 serial. **Current ticket:** `docs/factory/STATUS.md`.

Pointers: `CONTEXT.md` (vocabulary), `docs/factory/STATUS.md` (living board), `docs/architecture/MODULES.md`, `docs/dev/SWIFT.md`, `docs/dev/PARITY.md`, `docs/factory/PLAN.md` (conflict arbiter).

Skills (project wins on conflict; fixtures/fakes stay in `Tests/`; do not load `thermo-nuclear-code-quality-review`):

| Topic | Skill |
|---|---|
| `Package.swift` / module graph | `.grok/skills/swift-hexagonal-spm` |
| Evaluate / packs / corpus | `.grok/skills/swift-evaluate-parity` |
| Hooks / XPC / hostDenyText / doctor | `.grok/skills/swift-hook-xpc` |
| Pre-merge review | `.grok/skills/swift-thermo-nuclear-review` |
| Also | `~/.grok/skills/swift-pr-review`, `swift-concurrency`, `swift-testing-pro`, `swift-api-design-guidelines` |

Gate: `tools/gate.sh` (runs `preflight` + filtered tests via `tools/swift-6.3.3`). Warm `.build`. Do not wipe `.build` or `swift package clean` to prove a compile — clean ~12s is Foundation ModuleCache (6.3.3 has no prebuilt SDK overlays), not type-check. Details: `docs/dev/SWIFT.md`.

## Swift style contract

- Value types only in Domain/Engine/Packs/Presentation. `class` only at XPC/`NSObject` `RVService` edge.
- Newtypes: `PackID`, `RuleID`, `ShellCommand`. Closed `Decision` enum. No boolean `isDenied`.
- Small capability protocols (`PatternEngine`, `HostCodec`, `FrameRenderer`). Prefer `some`; `any` only for mixed lists.
- Functional core / imperative shell. Pure `evaluate` (no `Date()` / `FileManager` / `ProcessInfo`).
- Typed errors. `Sendable` + actors for stores. No `try!` / `!` on production paths.
- TUI: `reduce` + `render` → `[String]`.

## Forbidden (condensed)

- No `RV_BYPASS` or any env a hook child honors to skip evaluate.
- No allow-because-XPC-missed (down or skew must in-process evaluate).
- No Read/Edit/MCP hooks in v1.
- No host Allow / leftover-ask UI. Pi deny card is display-only (`{ render(width) => string[] }`, never a string). OpenCode toast is display-only chrome; `throw` remains the deny path.
- No foreign hook writes.
- No live-HOME tests.
- No command text in `os_log`. History stays off by default.
- No OS-enforced / Seatbelt claim. Grade is hook.
- No Linux / Windows / macOS 14 / 15 claim.

## Cursor Cloud specific instructions

The Cursor Cloud Agent VM is **Linux x86_64**, but this project is **macOS 26 / Apple Silicon only** — an intentional, source-level lock, not a missing dependency.

- Every module begins with `#if !arch(arm64) #error("rv v1 is Apple Silicon only") #endif`, and the code pulls in `Darwin`, `CryptoKit`, XPC (`NSXPCConnection`/`NSXPCListener`), launchd plists, and `.macOS(.v26)`. So on this VM **no `swift build`/`swift test` target compiles** and the `rv`/`rvd` binaries **cannot run**. Do that work on a macOS 26 Apple Silicon host with Swift 6.3.3 (see `docs/dev/SWIFT.md`), using `tools/swift-6.3.3` / `tools/gate.sh`.
- What *does* run on the Linux VM: the lint/structural gate **`tools/preflight.sh`** (pure `bash`+`grep`+`python3`, all present on the base image). It is the platform-independent half of `tools/gate.sh` and covers the module-law, purity, name-hygiene, and corpus-JSON checks. Run it directly; expect `0 failed` (one known `@_exported` warning).
- Do **not** run `tools/gate.sh` on this VM expecting success — after `preflight` it calls `tools/swift-6.3.3 test`, which needs the macOS `.xctoolchain` and will fail here. Installing a Linux Swift toolchain does not help: the `arch(arm64)` guard rejects x86_64 outright.
- Practical scope for a Linux Cloud Agent here: docs, config, corpus JSON, and any change validated by `tools/preflight.sh`. Anything requiring a Swift compile or the XPC/launchd runtime must be verified on macOS.
