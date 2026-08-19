# AGENTS.md — rv

Work only in `~/CodingProjects/rv`. Do not implement in sibling repos. Do not write foreign product names into this tree.

v1 platform: macOS 26, Apple Silicon only. Package tools Swift 6.3. Language mode 6.

Hexagonal modules; dependency arrows down; a test that needs a TTY to prove a **decision** is in the wrong module.

Ticket order T0→T1 then PLAN’s parallel rules. T0 serial.

Pointers: `docs/architecture/MODULES.md`, `docs/dev/SWIFT.md`, `docs/dev/PARITY.md`, `docs/factory/PLAN.md`.
Skills: `.grok/skills/swift-hexagonal-spm`, `.grok/skills/swift-evaluate-parity`, `.grok/skills/swift-hook-xpc`, `.grok/skills/swift-thermo-nuclear-review`, `~/.grok/skills/swift-pr-review`, `~/.grok/skills/swift-concurrency`, `~/.grok/skills/swift-testing-pro`, `~/.grok/skills/swift-api-design-guidelines`. Project skills win on conflict. Fixtures/fakes stay in `Tests/`. Do not load `thermo-nuclear-code-quality-review` on this repo.

Gate: `swift test --filter <Target>Tests` on a warm `.build`. Do not wipe `.build` or `swift package clean` to prove a compile — clean ~12s is Foundation ModuleCache (6.3.3 has no prebuilt SDK overlays), not type-check. Details: `docs/dev/SWIFT.md`.

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
