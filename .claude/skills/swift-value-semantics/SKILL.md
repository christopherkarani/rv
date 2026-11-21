---
name: swift-value-semantics
description: Use when Swift code has copying, mutation, identity, copy-on-write, large aggregates, or a struct-versus-class decision. Do not infer that every struct is cheap or every class is shared mutable state by accident.
---

# Swift value semantics

Choose semantics first, representation second. A value type should be substitutable by its value; a reference type should make identity and shared mutation intentional.

## Procedure

1. State whether callers expect independent values, shared identity, stable identity, or unique ownership. Check equality, hashing, caching, and mutation expectations.
2. Inspect stored members and their semantics. A struct containing references may still share mutable state; a class can expose a value-like façade but must enforce it.
3. Choose `struct`/`enum`, `class`, actor, or noncopyable value based on the invariant—not on a blanket style rule.
4. For large copyable values, measure before changing representation. Use copy-on-write only when aliasing and mutation frequency justify its storage and synchronization complexity.
5. Keep mutation APIs explicit. Check exclusivity, nested mutation, thread safety, and whether a getter unexpectedly copies or aliases data.
6. Test aliasing, independent mutation, equality/hash behavior, and performance at realistic sizes.

Read [references/value-semantics-guide.md](references/value-semantics-guide.md) for the aliasing matrix.

## Guardrails

- `let` prevents reassignment of a value binding; it does not make referenced objects immutable.
- Copy-on-write is a semantic promise plus an optimization, not a substitute for synchronization.
- Do not add a class solely to share a cache or avoid a copy without measuring and documenting identity.
- If duplication is illegal rather than merely expensive, use `swift-ownership` and model noncopyability. On Swift 6.4, unique growable storage is `UniqueArray` (Swift module), not a COW `Array` of boxes. `RigidArray` did not ship. Load `swift-64-span-inlinearray`.

## Completion contract

Report the intended aliasing/identity semantics, representation tradeoff, measured or reasoned copy cost, and tests that prove independent or shared mutation as intended.
