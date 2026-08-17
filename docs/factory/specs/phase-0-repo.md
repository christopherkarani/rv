# Phase 0 — Repo (T0)

Locked law: [`docs/factory/PLAN.md`](../PLAN.md). If this spec and PLAN disagree, PLAN wins. Implement only in `~/CodingProjects/rv`. This ticket is L0: a Swift 6.2 SPM package that compiles and whose empty-module tests pass.

## Goal

Stand up the product repository so later tickets have a stable module graph, style contract, and a pinned **0.11.0** upstream (`vendor/parity/PIN`).

A fresh agent finishing T0 must leave behind:

1. `Package.swift` for **macOS 26 / arm64 only**, Swift tools 6.2, language mode 6.
2. Twelve empty library modules from PLAN, each with its own test target.
3. `AGENTS.md` and `docs/dev/SWIFT.md` containing the PLAN Swift style contract **verbatim**.
4. `docs/architecture/MODULES.md` and `docs/dev/PARITY.md`.
5. A machine-readable 0.11.0 pin at `vendor/parity/PIN` plus extractor **placeholder** paths (no extractor, no pack JSON, no corpus).
6. `swift build` and `swift test` green.

T0 does not evaluate commands, render UX, speak XPC, or wire hosts.

## Non-goals

- Domain types, `evaluate`, `PatternEngine`, pack JSON, SKILL.md corpus (T1).
- Pretty / robot / browse CLI, ArgumentParser, `@main` `rv` (T2).
- `rvd`, `rv.ipc.v1` transport, launchd, XPC, in-process fallback behavior (T3).
- Host codecs, `install.sh`, `rv setup` / `uninstall`, `rv doctor` (T4–T7).
- Allow-once / allowlist (T8). Remaining catalog import (T9).
- License file. Do not invent `LICENSE`.
- Vendoring or cloning the upstream Rust tree into this repo.
- Writing the tokens `dcg` or `ryk` into any product file. Work only in this repo.
- GitHub Actions, Homebrew formula, `curl | sh` installer, live hook files, Mac app.
- Executable products `rv` / `rvd`. Third-party SPM dependencies.
- Linux, Windows, Intel, macOS 14/15 platforms or CI matrix claims.

## Depends on

Nothing in-repo except locked PLAN. The git repo already exists and already contains factory docs (`docs/factory/PLAN.md` and sibling specs). Do not re-init git. Do not rewrite or move PLAN.

Toolchain (operator machine, not installed by this ticket):

- Apple Silicon Mac (`uname -m` → `arm64`).
- macOS 26 SDK.
- Swift 6.2.x (`swift --version`). If the toolchain cannot parse `.macOS(.v26)`, the only allowed fallback is `.macOS("26.0")`. Do not lower the platform.

T1 must not start until T0’s definition of done is true.

## Parallel / worktree

**T0 is serial.** No sibling ticket, no second worktree, no `feat/t1-*` (or later) branch until `swift test` is green on these empty modules.

Land T0 on `main` (or `feat/t0-repo` merged to `main` before T1). After T0: **T1 only** on `main` / `feat/t1-engine`. Parallel worktrees begin only after T1’s corpus is green, per PLAN.

Do not share a working tree with another agent.

## Public surface (Package.swift modules, empty targets)

Package name: `rv`. No `dependencies:` array entries.

Products: **library-only** for every module. Do not add `.executable` products. T2 adds executable `rv` + ArgumentParser. T3 adds executable `rvd`. Encoding those later avoids a T0 `@main`.

Targets and allowed dependencies (arrows down; engine never imports CLI, TUI, or XPC):

| Target | Dependencies | Notes |
|---|---|---|
| `RVDomain` | none | Types in T1. |
| `RVTheme` | none | Palettes in T2. No business rules. |
| `RVEngine` | `RVDomain` | Must not depend on Packs, Hooks, CLI, TUI, Service. |
| `RVPacks` | `RVDomain` | Resource dir reserved; no JSON yet. |
| `RVPolicy` | `RVDomain` | Config/allowlist later. |
| `RVHooks` | `RVDomain` | Pi/Grok/OpenCode codecs later. |
| `RVIPC` | `RVDomain` | `rv.ipc.v1` Codable later. |
| `RVHistory` | `RVDomain` | **Stub.** Off by default forever until a later ticket enables it. Must not log argv. |
| `RVPresentation` | `RVDomain`, `RVTheme` | View models later. No ANSI. |
| `RVTUI` | `RVTheme`, `RVPresentation` | `reduce` + `render` later. Must not open a TTY. |
| `RVService` | `RVDomain`, `RVEngine`, `RVPacks`, `RVPolicy`, `RVIPC`, `RVHistory` | XPC/`NSObject` edge later. No ArgumentParser, no SwiftUI, no TUI/CLI/Presentation. |
| `RVCLI` | `RVDomain`, `RVEngine`, `RVPacks`, `RVPolicy`, `RVHooks`, `RVIPC`, `RVPresentation`, `RVTheme`, `RVTUI`, `RVService`, `RVHistory` | Thin client + fallback later. No regex, no pack parse. |

Each module has a matching `*Tests` target that depends only on that module.

Use this `Package.swift` (comments may be shortened, graph must match):

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "rv",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "RVDomain", targets: ["RVDomain"]),
        .library(name: "RVEngine", targets: ["RVEngine"]),
        .library(name: "RVPacks", targets: ["RVPacks"]),
        .library(name: "RVPolicy", targets: ["RVPolicy"]),
        .library(name: "RVHooks", targets: ["RVHooks"]),
        .library(name: "RVIPC", targets: ["RVIPC"]),
        .library(name: "RVService", targets: ["RVService"]),
        .library(name: "RVPresentation", targets: ["RVPresentation"]),
        .library(name: "RVTheme", targets: ["RVTheme"]),
        .library(name: "RVTUI", targets: ["RVTUI"]),
        .library(name: "RVCLI", targets: ["RVCLI"]),
        .library(name: "RVHistory", targets: ["RVHistory"]),
    ],
    targets: [
        .target(name: "RVDomain"),
        .target(name: "RVTheme"),
        .target(name: "RVEngine", dependencies: ["RVDomain"]),
        .target(
            name: "RVPacks",
            dependencies: ["RVDomain"],
            resources: [.copy("Resources/packs")]
        ),
        .target(name: "RVPolicy", dependencies: ["RVDomain"]),
        .target(name: "RVHooks", dependencies: ["RVDomain"]),
        .target(name: "RVIPC", dependencies: ["RVDomain"]),
        .target(name: "RVHistory", dependencies: ["RVDomain"]),
        .target(name: "RVPresentation", dependencies: ["RVDomain", "RVTheme"]),
        .target(name: "RVTUI", dependencies: ["RVTheme", "RVPresentation"]),
        .target(
            name: "RVService",
            dependencies: [
                "RVDomain", "RVEngine", "RVPacks", "RVPolicy", "RVIPC", "RVHistory",
            ]
        ),
        .target(
            name: "RVCLI",
            dependencies: [
                "RVDomain", "RVEngine", "RVPacks", "RVPolicy", "RVHooks", "RVIPC",
                "RVPresentation", "RVTheme", "RVTUI", "RVService", "RVHistory",
            ]
        ),
        .testTarget(name: "RVDomainTests", dependencies: ["RVDomain"]),
        .testTarget(name: "RVEngineTests", dependencies: ["RVEngine"]),
        .testTarget(name: "RVPacksTests", dependencies: ["RVPacks"]),
        .testTarget(name: "RVPolicyTests", dependencies: ["RVPolicy"]),
        .testTarget(name: "RVHooksTests", dependencies: ["RVHooks"]),
        .testTarget(name: "RVIPCTests", dependencies: ["RVIPC"]),
        .testTarget(name: "RVServiceTests", dependencies: ["RVService"]),
        .testTarget(name: "RVPresentationTests", dependencies: ["RVPresentation"]),
        .testTarget(name: "RVThemeTests", dependencies: ["RVTheme"]),
        .testTarget(name: "RVTUITests", dependencies: ["RVTUI"]),
        .testTarget(name: "RVCLITests", dependencies: ["RVCLI"]),
        .testTarget(name: "RVHistoryTests", dependencies: ["RVHistory"]),
    ],
    swiftLanguageModes: [.v6]
)
```

Empty-module rule: one Swift file per target, no product API. Use a public empty enum named after the module so `@testable import` has a symbol:

```swift
#if !arch(arm64)
#error("rv v1 is Apple Silicon only")
#endif

public enum RVDomain {}
```

Repeat per module (`RVEngine`, `RVPacks`, …). `RVHistory.swift` must also say, in a short comment: stub; history stays off by default; do not persist command text.

Tests use Swift Testing (no XCTest, no extra package). One smoke test per target:

```swift
import Testing
@testable import RVDomain

@Test func emptyModule_compiles() {
    let _: RVDomain.Type = RVDomain.self
}
```

Do not put `Date()`, `FileManager`, `ProcessInfo`, TTY, XPC, regex, or pack parsing in T0 sources.

## Files to create

Do not delete or edit `docs/factory/PLAN.md`. Do not create `LICENSE`. Do not write files outside this repo.

### Root

| Path | Required content |
|---|---|
| `Package.swift` | Exact graph above. |
| `.gitignore` | `.build/`, `.swiftpm/`, `xcuserdata/`, `.DS_Store`. Do not ignore `Package.swift` or docs. |
| `README.md` | Short: job (Mac-native destructive-command guard for agent **shell** hooks), names (`rv` / `rvd` / `RV_` / `~/.config/rv/`), platform (macOS 26 Apple Silicon), hosts (Pi / Grok / OpenCode), parity (pinned upstream 0.11.0 decisions + `rule_id`, not a Rust port), license deferred. Do not name other products. No install instructions that touch the operator’s live HOME. |
| `AGENTS.md` | See contract below. |

### Style + architecture docs

Copy this Swift style contract **verbatim** into both `AGENTS.md` and `docs/dev/SWIFT.md` (same bullets, same wording as PLAN):

- Value types only in Domain/Engine/Packs/Presentation. `class` only at XPC/`NSObject` `RVService` edge.
- Newtypes: `PackID`, `RuleID`, `ShellCommand`. Closed `Decision` enum. No boolean `isDenied`.
- Small capability protocols (`PatternEngine`, `HostCodec`, `FrameRenderer`). Prefer `some`; `any` only for mixed lists.
- Functional core / imperative shell. Pure `evaluate` (no `Date()` / `FileManager` / `ProcessInfo`).
- Typed errors. `Sendable` + actors for stores. No `try!` / `!` on production paths.
- TUI: `reduce` + `render` → `[String]`.

`AGENTS.md` must also state, in this repo’s voice:

- Work only in `~/CodingProjects/rv`. Do not implement in sibling repos. Do not write foreign product names into this tree.
- v1 platform: macOS 26, Apple Silicon only.
- Hexagonal modules; dependency arrows down; a test that needs a TTY to prove a **decision** is in the wrong module.
- Ticket order T0→T1 then PLAN’s parallel rules. T0 serial.
- Pointers: `docs/architecture/MODULES.md`, `docs/dev/SWIFT.md`, `docs/dev/PARITY.md`, `docs/factory/PLAN.md`.
- Condensed forbidden list from PLAN (at least: no `RV_BYPASS`, no allow-because-XPC-missed, no Read/Edit/MCP hooks in v1, no foreign hook writes, no live-HOME tests, no command text in `os_log`, no OS-enforced/Seatbelt claim, no Linux/Windows/14/15 claim).

`docs/dev/SWIFT.md` is the style page: verbatim contract plus file/target layout (`Sources/<Module>/`, `Tests/<Module>Tests/`), Swift Testing, `package` internals later, no `try!` / IUO on production paths.

`docs/architecture/MODULES.md` is **one** page (not twelve files). Copy PLAN’s module table (Owns / Must not) for all twelve modules, plus the dependency graph from this spec. Mark `RVHistory` as a stub. Say each module will keep a small public API.

### Parity + 0.11.0 pin

`docs/dev/PARITY.md` must pin. Use these field names. Do **not** write foreign product names in this file:

| Field | Value |
|---|---|
| Upstream | `https://github.com/Dicklesworthstone/destructive_command_guard` |
| Version | **0.11.0** |
| Git tag | `v0.11.0` |
| Tag object | `6d4fcaef45d6b207a291158dc4077e54e6be685c` |
| Commit | `2ed7eeef1ae63d204495f02312c657dd6d9bf73d` |
| v1 scoreboard | Same `Decision` + `rule_id` as the pinned **0.11.0 engine source** (not marketing tables). Critical/high deny; medium/low allow + match. Not line-for-line Rust. Not an alias of the upstream binary. |
| Not a v1 gate | Agree-rate against an upstream CLI on PATH. |

Also state PLAN’s evaluation order (for later tickets, not implemented here): normalize → quick-reject → safe patterns first → destructive → default allow.

Machine-readable pin `vendor/parity/PIN` (plain text, these keys):

```
source=https://github.com/Dicklesworthstone/destructive_command_guard
version=0.11.0
tag=v0.11.0
tag_object=6d4fcaef45d6b207a291158dc4077e54e6be685c
commit=2ed7eeef1ae63d204495f02312c657dd6d9bf73d
```

### Extractor placeholder paths (create empty; do not extract)

Pinned 0.11.0 packs are **Rust sources**, not JSON. T1/T9 extract JSON **data**. T0 only reserves paths.

**Upstream (do not clone or copy into rv in T0):**

| Path at tag `v0.11.0` | Role |
|---|---|
| `SKILL.md` | Golden table for L2 corpus (T1). |
| `src/packs/core/git.rs` | `core.git` |
| `src/packs/core/filesystem.rs` | `core.filesystem` |
| `src/packs/core/mod.rs` | Core pack module |
| `src/packs/mod.rs` | Pack registry |
| `src/packs/*/` | Remaining catalog (T9). Includes `windows/` as **data** only — do not claim Windows support. |
| `docs/packs/README.md` | Pack ID index |

**Downstream placeholders (create in T0):**

| rv path | Later owner |
|---|---|
| `vendor/parity/PIN` | T0 (this ticket) |
| `vendor/parity/EXTRACT.md` | T0 map of upstream → dest; say “no extractor in T0; T1 fills core JSON; T9 fills catalog.” Do not write foreign product names in this file. |
| `Sources/RVPacks/Resources/packs/.gitkeep` | T1: `core.git` + `core.filesystem` JSON. T9: remaining JSON, default-off. |
| `Tests/RVEngineTests/Fixtures/corpus/.gitkeep` | T1 SKILL.md + core fixtures. |
| `tools/extract-packs/README.md` | Future extractor entrypoint. No script that fetches or parses upstream. |

`vendor/parity/EXTRACT.md` must list the upstream and downstream tables above and forbid vendoring the Rust tree.

### Sources and tests (empty)

Create all of:

```
Sources/RVDomain/RVDomain.swift
Sources/RVEngine/RVEngine.swift
Sources/RVPacks/RVPacks.swift
Sources/RVPacks/Resources/packs/.gitkeep
Sources/RVPolicy/RVPolicy.swift
Sources/RVHooks/RVHooks.swift
Sources/RVIPC/RVIPC.swift
Sources/RVService/RVService.swift
Sources/RVPresentation/RVPresentation.swift
Sources/RVTheme/RVTheme.swift
Sources/RVTUI/RVTUI.swift
Sources/RVCLI/RVCLI.swift
Sources/RVHistory/RVHistory.swift
Tests/RVDomainTests/RVDomainTests.swift
Tests/RVEngineTests/RVEngineTests.swift
Tests/RVEngineTests/Fixtures/corpus/.gitkeep
Tests/RVPacksTests/RVPacksTests.swift
Tests/RVPolicyTests/RVPolicyTests.swift
Tests/RVHooksTests/RVHooksTests.swift
Tests/RVIPCTests/RVIPCTests.swift
Tests/RVServiceTests/RVServiceTests.swift
Tests/RVPresentationTests/RVPresentationTests.swift
Tests/RVThemeTests/RVThemeTests.swift
Tests/RVTUITests/RVTUITests.swift
Tests/RVCLITests/RVCLITests.swift
Tests/RVHistoryTests/RVHistoryTests.swift
```

## Acceptance

T0 passes when all of the following are true:

1. `swift build` succeeds (PLAN L0) on Apple Silicon with the macOS 26 / Swift 6.2 package.
2. `swift test` is green. Every `*Tests` target runs and its smoke test passes.
3. `swift package dump-package` lists exactly the twelve library products and twelve test targets named above. No executable products. No package dependencies.
4. `Package.swift` platforms are only `.macOS(.v26)` or the string fallback `.macOS("26.0")`. No iOS/Linux/Windows/macOS 14/15.
5. Each `Sources/<Module>/<Module>.swift` contains the `arm64` `#error` guard and no product logic.
6. `AGENTS.md` and `docs/dev/SWIFT.md` contain the six style-contract bullets verbatim.
7. `docs/architecture/MODULES.md` and `docs/dev/PARITY.md` exist and match this spec.
8. `vendor/parity/PIN` reads `version=0.11.0` and `tag=v0.11.0`.
9. Extractor placeholders exist and contain **no** upstream Rust, **no** pack JSON, **no** SKILL.md copy.
10. There is **no** `LICENSE` file.
11. Product-tree grep: no file outside `docs/factory/` contains the tokens `dcg` or `ryk` (any case). Work stayed in this repo.
12. Factory law is intact: `docs/factory/PLAN.md` unchanged.

## Test plan

Run on the operator’s Apple Silicon Mac, from the repo root. Do not use a temp HOME that points at the human’s real `~/.config`. Do not invoke foreign CLIs or host CLIs.

1. `uname -m` → `arm64`. `swift --version` → 6.2.x.
2. `swift build`
3. `swift test`
4. Confirm twelve test targets, e.g. `swift test --list-tests` (or equivalent) includes `RVDomainTests`, `RVEngineTests`, `RVPacksTests`, `RVPolicyTests`, `RVHooksTests`, `RVIPCTests`, `RVServiceTests`, `RVPresentationTests`, `RVThemeTests`, `RVTUITests`, `RVCLITests`, `RVHistoryTests`.
5. `swift package dump-package` — assert product/target names and empty `dependencies`.
6. Grep guard: no `RV_BYPASS`, no `LICENSE`, no `linux`, no `.macOS(.v14)` / `.v15` in `Package.swift`.
7. Grep `AGENTS.md` and `docs/dev/SWIFT.md` for `No boolean \`isDenied\`` and `reduce` + `render`.
8. `test -f vendor/parity/PIN` and `grep -q 'version=0.11.0' vendor/parity/PIN`.
9. `test ! -e LICENSE`.
10. Placeholders are empty of payload: `Sources/RVPacks/Resources/packs` has only `.gitkeep`; `tools/extract-packs` has only `README.md`.
11. Product-tree grep: `rg -i --glob '!docs/factory/**' 'dcg|ryk'` is empty.

No L2 corpus, L3 hook, or L4 setup tests in T0.

## Forbidden

From PLAN, and T0-specific:

- `RV_BYPASS` or any env a future hook child could honor to skip evaluate.
- Implementing evaluate, hooks, XPC, setup, or pretty deny in this ticket.
- Adding ArgumentParser, regex engines, pack parsers, or `@main`.
- Cloning the upstream tree, copying `SKILL.md` / `*.rs` packs, or running an extractor.
- Writing `LICENSE` or claiming a license.
- Claiming Linux/Windows/Intel/macOS 14/15 support, or OS-enforced / Seatbelt.
- Writing the tokens `dcg` or `ryk` into any product file. Work only in this repo.
- Writing foreign hook files or the human’s real HOME.
- Starting T1 (or any later ticket) in parallel.
- Telemetry, SaaS, network install of packs.
- Editing `docs/factory/PLAN.md`.

## Open questions

Resolved for T0 (do not re-litigate):

- License is deferred — ship without `LICENSE`.
- Executables `rv` / `rvd` wait for T2 / T3.
- Upstream pin is **0.11.0** / tag `v0.11.0` / commit `2ed7eeef1ae63d204495f02312c657dd6d9bf73d` at `vendor/parity/PIN`.
- Pack JSON schema and SKILL.md fixture format belong to T1, not T0.

Still open (later tickets; T0 must not invent answers):

- Exact extracted JSON schema and `rule_id` spellings (verify against the pinned 0.11.0 source in T1).
- ArgumentParser version pin (T2).
- Whether T1’s extractor lives as a Swift tool or a one-shot script under `tools/extract-packs/` (T1 chooses; T0 only reserved the directory).

## Definition of done

T0 is done when a cold `swift test` in `~/CodingProjects/rv` is green on empty modules, the twelve-library graph is locked, `AGENTS.md` + `docs/dev/SWIFT.md` carry the PLAN style contract, `MODULES.md` + `PARITY.md` exist, 0.11.0 is pinned at `vendor/parity/PIN`, extractor paths are empty placeholders, there is no `LICENSE`, and no file outside `docs/factory/` contains the tokens `dcg` or `ryk`.

Gate: **L0**. Next ticket: **T1 only**.
