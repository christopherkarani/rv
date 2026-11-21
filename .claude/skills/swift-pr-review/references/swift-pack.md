# Swift pack (thin)

Load this before reviewing or fixing. Then load the **project overlay**.
Do not load Zig skills.

## Project overlay (wins)

If the repo has any of these, read them and treat them as law:

| Path | When |
|------|------|
| `AGENTS.md` / `Agents.md` | Always |
| `docs/dev/SWIFT.md` | Always if present |
| `docs/architecture/MODULES.md` | Module graph / ownership |
| `.claude/skills/swift-hexagonal-spm/SKILL.md` | Package.swift, imports, `class` placement, test targets |
| `.claude/skills/swift-evaluate-parity/SKILL.md` | evaluate, packs, Decision, normalize |
| `.claude/skills/swift-hook-xpc/SKILL.md` | hooks, XPC, codecs, TUI reduce/render |

Generic Swift taste below is a fallback. Project law overrides it.

Public naming and labels: `references/api-pack.md` +
`swift-api-design-guidelines`. Maintainability judo:
project `swift-thermo-nuclear-review`. Do not load
`thermo-nuclear-code-quality-review`.

## Leverage the type system (required hunt)

The compiler is the cheapest reviewer. A finding is **missed leverage**
when this PR’s solution uses flags, `String`, `Any`, or copy-paste
where Swift could make the illegal state unrepresentable and the
module **deeper**.

Ask of every new type / function this PR added:

1. Could a closed `enum` or newtype delete a branch callers must get right?
2. Is there a **real seam** (two adapters, or production + test) that
   should be a small capability protocol + generic/`some`?
3. Can one generic (or protocol extension) replace two near-copies?
4. Do errors belong in a typed `throws` / `Result` the `switch` must cover?
5. Does the new interface hide work, or leak implementation (`isDenied`,
   extra flags, unlabeled `String`s)?

Prefer the option that **deletes branches, flags, or wrappers** and
keeps the **interface small**.

| Instead of | Prefer |
|------------|--------|
| `class` in Domain / Engine / packs / presentation | `struct` / `enum`; `actor` only for a store |
| `isDenied` / paired booleans | Closed `enum` (`Decision`) |
| `String` IDs | Newtype (`PackID`, `RuleID`) |
| `any Protocol` for one concrete type | `some Protocol` or `<E: Protocol>` |
| Taxonomy protocol (“Fooable”) with one adopter | Concrete type; protocol at the **second** adapter |
| Two near-identical functions | Generic or protocol extension on the shared role |
| `try!` / `as!` / IUO | Typed `throws` or `Optional` at the real seam |
| `Date()` / `FileManager` inside `evaluate` | Inject time / IO at the shell |
| Unstructured `Task { }` | Caller-owned `Task` or `withTaskGroup` |
| Non-`Sendable` value crossing actors | Value type + `Sendable` |
| `default:` in a closed-set `switch` | Exhaustive cases |
| New `@_exported import` | Callers import the owning module |

`any` is correct for a **mixed list**. Do not “fix” that to `some`.

Do **not** invent a protocol, macro, or generic that only one call site
uses. That is shallowness, not POP.

## Capability protocols

Small protocols named for what a caller **does** (`PatternEngine`,
`HostCodec`, `FrameRenderer`). Prefer `some`. Use `any` only when the
collection is heterogeneous.

One adapter means a hypothetical seam — do not add the protocol yet
(codebase-design). Two adapters means a real seam. When the seam is
real, **do** introduce the protocol and genericize the caller
(`evaluate<E: PatternEngine>`) so the module stays deep.

## Functional core / imperative shell

Pure functions take values in and return values. No hidden `Date()`,
`FileManager`, `ProcessInfo`, or TTY. Side effects live in CLI / XPC /
hook adapters.

## Concurrency

- `Sendable` on values that cross isolation
- `actor` for mutable stores, not for every type
- No `nonisolated(unsafe)` without a written invariant
- Prefer structured concurrency

## Tests

- Prove **decisions** in the engine/domain test target, not in a TUI test
- A test that needs a TTY to prove allow vs deny is in the wrong module
- Match the repo: Swift Testing (`import Testing`) vs XCTest — do not mix in
- Filter to the touched module; do not claim a different toolchain is green

## Toolchain

If `.swift-version` or a project skill pins a toolchain, use that before
`/usr/bin/swift`. Do not invent a version.

On Swift 6.4, also load `swift-64-whats-new` when the diff uses
`Continuation`, `UniqueArray`, async `defer`, `~Sendable`, `anyAppleOS`, or
Swift Build. Prefer `Continuation` over `CheckedContinuation` when
resume-once is compile-time. Do not put `~Copyable` elements in `Array`.
Do not write `RigidArray`. `@c` is 6.3; 6.4 only adds Span wrappers.

## Fix bias

Surgical. Delete slop first. Do not add a protocol, macro, or generic
constraint that only one call site uses. Do not commit or push.
