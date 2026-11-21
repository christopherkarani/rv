---
name: swift-functional-architecture
description: >
  Default design skill for pragmatic functional Swift: functional core /
  imperative shell, values and composable transformations, enums for closed
  state, generics that preserve relationships, protocols as capabilities,
  intentional some/any boundaries, and effects pushed to adapters. Use for
  non-trivial Swift design and implementation. Also /swift-functional-architecture.
metadata:
  short-description: functional Swift design default
---

# Swift Functional Architecture

Default design skill for non-trivial Swift design and implementation.

Core doctrine:

> Model data explicitly, keep behavior composable, isolate effects, preserve type information, and use the compiler to enforce relationships and invariants.

Prefer the smallest specialist skill when the task is narrowly about types, concurrency, testing, API naming, PR review, or broad architecture discovery. This skill is the default when shaping or implementing domain behavior.

## Shape of a good design

```text
typed input
→ pure/composable transformations
→ typed result
→ effectful adapter
```

Push effects to the shell:

- filesystem, environment, process execution
- XPC / network / IPC
- terminal I/O, logging
- clocks, randomness, persistence
- setup/install mutations

Domain logic should not reach for ambient state such as `FileManager.default`, `ProcessInfo.processInfo`, or `Date()` when those values can be passed explicitly.

## Values and functions first

Prefer:

- value semantics and immutable data by default
- explicit inputs and outputs
- functions that model meaningful transformations
- local mutation when it simplifies an implementation without leaking state

Use classes when identity, lifecycle, framework constraints, observation, or shared resource ownership are real. Do not use classes merely because behavior exists. Do not use structs dogmatically when identity matters.

## Model state in types

Prefer enums and associated values for closed state spaces.

Avoid boolean/optional combinations that permit invalid states.

Use exhaustive switches when adding a domain state should force callers to reconsider behavior.

Prefer semantic types (`PackID`, `RuleID`, `ShellCommand`) over raw primitives when the distinction matters.

Make invalid states difficult to represent without turning simple code into a type puzzle.

## Generics preserve relationships

Use generics when the compiler should know a real relationship between types.

Ask: what incorrect program becomes impossible?

Good uses: input/output relationships, same-type constraints, representation-independent algorithms, eliminating casts, preserving associated-type relationships.

Keep generic complexity local. Do not thread type parameters through unrelated modules merely to avoid one existential boundary.

When advanced typing makes call sites significantly harder without proportionate safety gain, prefer the simpler design.

## Protocols are capabilities

Protocols should name meaningful capabilities, not accidental implementation reuse.

Prefer narrow protocols. Prefer composition over large kitchen-sink protocols.

Reach for a protocol when there are multiple real implementations, a meaningful abstraction boundary, or a test seam that must exist. Do not invent protocols solely for mocks when one real implementation plus injected values is enough.

## `some` / `any` are deliberate

- Prefer concrete types at module edges when the concrete type is the API.
- Use `some` to hide a concrete type while preserving a single underlying type.
- Use `any` only when runtime heterogeneity is intentional.
- Prefer constrained existentials over open-ended erasure when possible.

Erasure is a design choice, not a convenience escape hatch.

## Deep modules

Hide complexity behind small, stable interfaces.

Callers should know less, not more. A good module makes the next change cheap to make or remove.

Do not expose internal coordination types, temporary product types, or framework accidents as public surface.

## Concurrency and ownership

Actors, `Sendable`, tasks, and locks belong at effect and ownership boundaries. Keep the functional core free of ambient concurrency when the work is a pure transformation.

Prefer structured concurrency. Make cancellation and lifetime explicit. Do not sprinkle `@MainActor` or unstructured `Task {}` to silence diagnostics.

For deeper concurrency work, load `swift-concurrency`. On Swift 6.4, load `swift-64-whats-new` for 6.4-only APIs (`Continuation`, `UniqueArray`, async `defer`, `@c`).

## Testing posture

Prefer deterministic tests over the functional core: pure inputs, pure outputs, injected clocks/filesystem/env at the shell.

For Swift Testing craft, load `swift-testing-pro`.

## When to hand off

| Need | Skill |
| --- | --- |
| Generics / protocols / `some`/`any` / enum modeling depth | `swift-type-system-architecture` |
| Actors / `Sendable` / tasks / cancellation | `swift-concurrency` |
| Swift 6.4-only APIs | `swift-64-whats-new` |
| Swift Testing quality | `swift-testing-pro` |
| Broad functional evolution candidates | `swift-functional-codebase-evolution` |
| Broad deep-module / boundary refactors | `swiftify-codebase-architecture` |
| Discover → spec → implement → review → ticket PRs | `swift-architecture-pipeline` |
| Public/internal API naming fluency | `swift-api-design-guidelines` |

## Definition of done (design)

A change is well-shaped when:

- requested behavior is correct
- the functional core remains explicit
- effects remain at appropriate boundaries
- important state is modeled in types
- useful type relationships are compiler-checked
- generic complexity remains local
- protocols represent meaningful capabilities
- existential erasure is intentional
- module depth is preserved or improved
- concurrency and ownership are clear
- tests prove meaningful behavior

The best code is not the code using the most Swift features.

The best code makes domain behavior obvious, composition natural, invalid programs difficult to express, and future changes cheap to make or remove.
