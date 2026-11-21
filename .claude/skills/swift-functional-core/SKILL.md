---
name: swift-functional-core
description: Use when a Swift feature contains policy, evaluation, parsing, validation, state transitions, or deterministic business logic that can be separated from I/O. Do not force this skill onto inherently imperative resource or UI code.
---

# Swift functional core

Keep decisions deterministic and effects at the boundary. Functional design here means explicit data flow and testable invariants, not a ban on mutation or objects.

## Procedure

1. Separate inputs, decision logic, state transitions, and effects. Identify the smallest pure function or value reducer that can express the requirement.
2. Model outcomes as domain types: enums with associated values, typed values, and explicit error/indeterminate cases rather than sentinel strings or flags.
3. Make dependencies explicit at the shell. Pass clocks, randomness, filesystem, network, and process capabilities through narrow interfaces or values.
4. Keep the core free of global state, hidden task scheduling, logging side effects, and environment reads.
5. Test the transition table and properties first; test adapters with focused integration checks.
6. Keep mutation where it makes ownership, performance, or state transitions clearer. Do not copy large data merely to appear functional.

Read [references/core-boundary-guide.md](references/core-boundary-guide.md) when choosing boundaries or designing test seams.

On Swift 6.4, store async outcomes with `await Result { try await … }` (SE-0530) when the core must treat success/failure as a value. Keep effects at the shell.

## Guardrails

- A pure function may return a command/effect description instead of performing the effect.
- Do not introduce a protocol for every dependency; a closure or concrete value is often clearer.
- Do not hide policy in a callback, global singleton, actor, or logging side effect.
- Exhaustive state modeling is more valuable than a large abstraction hierarchy.

## Completion contract

Show the pure input/output contract, the effect boundary, transition coverage, and deterministic test evidence.
