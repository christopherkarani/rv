---
name: swift-hexagonal-spm
description: >
  Hexagonal Swift 6 SPM module law for rv. Use when editing Package.swift,
  adding a module or test target, adding product or executableTarget rv/rvd,
  ArgumentParser, main.swift / @main in a library, @_exported, or a T2∥T3
  Package.swift merge. Also /swift-hexagonal-spm.
metadata:
  short-description: rv module law
---

# swift-hexagonal-spm

Internal. Module law for this package. Not a public-API sculptor.

Law lives in `AGENTS.md`, `docs/architecture/MODULES.md`, `docs/dev/SWIFT.md`.
This skill is the preflight those files do not run. Ticket ownership of
`Package.swift` is in [references/package-ownership.md](references/package-ownership.md).

Evaluate contract → `swift-evaluate-parity`. Hook / XPC / `hostDenyText` →
`swift-hook-xpc`.

## Load first

1. `AGENTS.md`
2. `docs/architecture/MODULES.md`
3. `docs/dev/SWIFT.md`
4. `Package.swift` as it is **now**

Do not invent a module. Do not restyle the graph from memory.

## Toolchain

Pin is `.swift-version` (`6.3.3`). Language mode 6. macOS 26, Apple Silicon.

`/usr/bin/swift` on this machine may be Xcode 6.2. Before any compile claim:

```bash
tools/swift-6.3.3 --version   # expect Apple Swift version 6.3.3
```

If that wrapper fails (missing toolchain), stop and say so. Do not use
`swiftly run 6.3.3` unless you have just proven that binary.

Do not wipe `.build` or run `swift package clean` to prove a compile. Clean
`swift build` ~12s is Foundation overlay rebuild in `.build/.../ModuleCache`
(6.3.3 has no prebuilt SDK modules), not rv type-check. Incremental Engine
edits are <1s. Numbers: `docs/dev/SWIFT.md`.

Gate: `tools/gate.sh <Target>Tests` for the module you touched (preflight +
filtered test via `tools/swift-6.3.3`), against a warm `.build`.
`RVCorpusTests` is the only multi-module test target (Domain + Engine + Packs).

## Steps

1. Name the module that owns the change. If two modules would both need the
   type, it belongs in the lower one (`RVDomain` or the existing protocol).
2. Read that row in `MODULES.md` (Owns / Must not) and its **Dependency graph**
   table. A new import that is not on that row is a graph edit — stop and write a
   merge plan, or load the package-ownership reference.
3. Implement with `AGENTS.md` + `SWIFT.md`. Do not restyle from this file.
4. Put the proof in the matching `Tests/<Module>Tests` target. The only
   exception is `RVCorpusTests`.
5. Run `tools/gate.sh` for the touched target(s).

## Graph and tests

The graph is the Dependency graph table in `MODULES.md`. Do not implement from
a remembered ban-list.

A test that needs a TTY to prove a **decision** is in the wrong module.
Decisions are proven in `RVEngineTests` / `RVCorpusTests`. TTY tests prove
pretty / browse / allow-once entry, not allow vs deny.

Do not add `@_exported import`. Callers that need `Decision` import `RVDomain`.
`*Tests` list only their module in `Package.swift`. Importing `RVDomain` from
an Engine test **source file** is not a graph edit. Only `RVCorpusTests` may
*list* more than one module.

Existing `@_exported import RVDomain` in `RVEngine` / `RVPacks` is T1 debt.
Do not add more. Do not delete it in a ticket that does not own those files.

## Anti-patterns

| If you are about to | Do this instead |
|---|---|
| Add `class` in Domain/Engine/Packs/Presentation | `struct` / `enum` / `actor` (stores). `class` **declarations** only at `RVService` / XPC `NSObject`. |
| Put `main.swift` or `@main` in `RVCLI` / `RVService` | Separate `executableTarget` (`Sources/rv`, `Sources/rvd`). See package-ownership. |
| Import `RVPacks` from `RVEngine` | Pass `[PackSnapshot]` + `CompiledPacks` in |
| Prove deny in a TUI/CLI test | Assert `evaluate` in Engine/Corpus |
| Give `*Tests` a second **Package.swift** dependency | Only `RVCorpusTests` may list three |
| Add ArgumentParser and `rvd` in one ticket | [package-ownership.md](references/package-ownership.md) |
| Use `PackID(rawValue:)!` | Non-failable `init(rawValue:)` |
| Revert product `rv` to restore “no executables” | That snapshot is pre-T2. Do not delete a legal `rv`. |

## Preflight (run on the diff before claiming done)

**Run `tools/gate.sh` for the touched target(s).** It runs `tools/preflight.sh`
then filtered tests on 6.3.3. Then re-read the remaining list for anything the
script can't catch (semantic judgments).

Re-read this list against the staged/unstaged Swift + `Package.swift` diff:

- [ ] Every new import is on the `MODULES.md` graph for that target.
- [ ] No `class` declarations outside `RVService` / XPC `NSObject`.
- [ ] No `isDenied`, no `try!`, no IUO on production paths.
- [ ] No new `@_exported import`. No `import XCTest`. No `import RVPacks` in Engine.
- [ ] Decision tests do not open a TTY.
- [ ] No `main.swift` / `@main` inside a library target (`RVCLI`, `RVService`, …).
- [ ] `Package.swift` executable / ArgumentParser edits match one ticket’s
      ownership row — or a written merge plan exists.
- [ ] `tools/swift-6.3.3 --version` is 6.3.3 and `tools/gate.sh` for the touched
      target is green.
