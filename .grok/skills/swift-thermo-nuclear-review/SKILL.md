---
name: swift-thermo-nuclear-review
description: >
  Harsh Swift maintainability review for rv: hexagonal module judo, 1k-line
  files, spaghetti growth, value-type/enum leverage, and Swift API Design
  Guidelines on new public seams. Use for a Swift thermo-nuclear review,
  /swift-thermo-nuclear-review, or as the thermo lane in /swift-pr-review
  and /multi-agent-swift-pr-review on this repo. Do not use the generic
  thermo-nuclear-code-quality-review skill here.
metadata:
  short-description: rv Swift thermo + API
---

# Swift thermo-nuclear review (rv)

Internal. This repo’s thermo pass. **Do not** load
`thermo-nuclear-code-quality-review` — that rubric is TypeScript/`unknown`/
`any` and will miss rv law.

Review the **RIGHT side** of the diff. High conviction only.

## Load first

1. Repo `AGENTS.md`, `docs/dev/SWIFT.md`, `docs/architecture/MODULES.md`
2. This file
2b. `~/.grok/skills/swift-pr-review/references/swift-pack.md`
    (**Leverage the type system**)
3. For **new or re-signed** `public` / `package` APIs:
   `~/.grok/skills/swift-pr-review/references/api-pack.md` then
   `~/.grok/skills/swift-api-design-guidelines/SKILL.md`
4. If the hunk touches that area, the matching project skill:
   `swift-hexagonal-spm` · `swift-evaluate-parity` · `swift-hook-xpc`

Project overlay wins. Spec-named symbols are constraints (api-pack).

## Bar

Be ambitious about **deleting** complexity. Do not rubber-stamp “it
compiles” or “tests are green.”

1. **Judo / type system.** Prefer a closed `enum`, newtype, generic, or
   **real-seam** capability protocol (`some` / `<E:>`) that removes
   branches, flags, or wrappers. A missed `Decision` / `RuleID` /
   `PatternEngine`-shaped seam that would collapse `if`s is a finding,
   not a nit. Load `swift-pack.md` **Leverage the type system**. One
   adopter is not a protocol. Two adapters is.
2. **1k lines.** A file this PR pushes from under ~1000 lines to over is
   a smell. Prefer extract, not waive.
3. **No spaghetti.** New special-case `if`s bolted onto an unrelated
   flow belong in the type that already owns the concept.
4. **Right module.** Arrows down (`MODULES.md`). Engine never imports
   CLI / TUI / XPC / Packs. A TTY test that proves a **decision** is in
   the wrong module.
5. **Value types.** `class` only at `RVService` / `NSObject`. No
   `isDenied`. No `try!` / IUO on production paths. `evaluate` stays
   pure (no `Date()` / `FileManager` / `ProcessInfo`).
6. **Deep, not clever.** No protocol + one adopter. No `any` where
   `some` or `<E:>` works (mixed lists are the exception). Prefer
   **depth**: lots of behavior behind a small typed interface. A
   pass-through wrapper is a finding. A capability protocol at a real
   seam that hides the engine is not.
7. **API fluency.** New public call sites must read without opening the
   body. Load api-pack. Do **not** rename a PLAN/ticket-named factory.
   Missing `///` only on decls this diff added.

## Flag

- File crossing ~1000 lines
- Feature logic leaking into a shared path (Theme deciding deny, TUI
  switching on `Decision` when Presentation already has display seams)
- `class` in Domain / Engine / Packs / Presentation
- Free function that collides with an instance property (call sites
  need a module qualifier)
- Unlabeled members on a **public** tuple
- New public boolean query that does not read as an assertion (unless
  spec-locked)
- `Date()` / I/O inside a declared-pure function
- Duplicate helper when the owning module already has the canonical one

## Severity

| Finding | Severity |
|---------|----------|
| Contract break (`class` in a value layer, `Date()` in `evaluate`, TTY proving Decision) | major |
| Public call site ambiguous / wrong labels on a new seam | major |
| File crosses 1k / spaghetti growth | major |
| Pure redesign, no behavior delta | **minor** (never blocker) |
| Spec-locked leftover | report-only |
| Taste rename | drop |

## Output

Use the MAPR issue block (`Severity`, `File`, `RootCause`, `Suggestion`,
`Fixable`). Empty Issues if clean.

## Pre-flight (before you deliver)

- [ ] Ran `tools/gate.sh` (or `tools/preflight.sh` + filtered tests) — 0 failures
- [ ] Did **not** load `thermo-nuclear-code-quality-review`
- [ ] Loaded `AGENTS.md` + `MODULES.md` + `SWIFT.md`
- [ ] New/re-signed public APIs: loaded api-pack + ADG
- [ ] Spec-named symbols were not flagged for rename
- [ ] Pure judo with no behavior delta is **minor**
- [ ] No invented issues on unchanged APIs
