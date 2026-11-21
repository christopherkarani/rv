# Architecture lane — PR-scoped

This is **not** `/improve-codebase-architecture`. Do not write an HTML
report. Do not start a grilling loop. Do not survey the whole repo.

You **do** take the same aim as that skill: turn what this PR just
shipped into a **deeper** module — small interface, lots of behavior,
testable at the seam — using Swift’s type system (enums, newtypes,
generics, capability protocols at **real** seams).

You review how **this change** sits in the module graph and whether it
deepened or shallowed the modules it touched. Then propose a
**surgical** deepening of *this* solution, not a whole-repo rewrite.

## Vocabulary

From `.claude/skills/codebase-design/SKILL.md`. Use these words exactly:

- **module** — anything with an interface and an implementation
- **interface** — everything a caller must know (types, errors, ordering)
- **depth** — lots of behavior behind a small interface
- **seam** — where that interface lives; where behavior can change
- **adapter** — a concrete thing that satisfies the interface
- **leverage** — what callers get from depth
- **locality** — change and tests concentrate in one place

Do not say “service”, “component”, “API”, or “boundary”.

## Scope

1. Changed files → owning **module** (from `MODULES.md` or directory)
2. One hop: modules that import it, and modules it newly imports
3. Stop. Broader means “the graph around this PR”, not “the product”.

If `MODULES.md` exists, a new import that is not on that row is a graph
edit. Emit a **major** unless the PR’s ticket owns the graph change.

## Questions (every meaningful hunk)

- Did this PR make the module **shallower** (more interface, same behavior)?
- Could the same behavior sit behind a **smaller** interface (fewer
  methods, fewer flags, types that make illegal states unrepresentable)?
- Is the new logic in the module that already owns the concept?
- Would deleting the new type **concentrate** complexity (pass-through) or
  **reappear across callers** (earning its keep)?
- Is a new protocol a real seam (two adapters) or a hypothetical one?
  If the seam is real, did the PR miss a generic/`some` caller?
- Did tests move to the interface, or past it (wrong shape)?
- Did feature logic leak into a shared path?
- Did a previously cohesive module become more coupled or stateful?
- Did this PR copy logic that a generic or protocol extension would own?

## What to emit

Issues with a concrete Suggestion that this PR can land:

- Move a type down to the module that already owns it
- Collapse a pass-through wrapper
- Replace a boolean mode with a closed enum the module already has
- Introduce a **capability** protocol + generic/`some` at a **real**
  seam (two adapters); do not invent a one-adopter protocol
- Stop a new upward import; invert the dependency
- Relocate a decision test out of a TTY/TUI target
- Hide work behind the existing interface instead of growing it

Do **not** emit:

- Whole-repo deepening candidates (that is the other skill)
- Speculative “extract a package” with no surgical first step
- ADR-forbidden reshapes unless this PR already reopened the ADR —
  then mark the conflict in the Description

## Recommendation strength (in Summary only)

- **Strong** — this PR made the graph worse, or a ≤200 LOC deepening
  deletes the complexity it just added
- **Worth exploring** — adjacent module is shallow; say so, AutoFix no
  unless the Suggestion is surgical
- **Speculative** — do not file as major

Summary must answer: deepened, shallowed, or unchanged — and name the
modules.
