---
name: swift-64-concurrency
description: >
  Use when Swift 6.4 concurrency APIs appear: async defer, withTaskCancellationShield,
  Continuation / withContinuation, ~Sendable, unused throwing Task warnings, async
  Result, UnownedTaskExecutor Hashable. Do not invoke for ordinary actor/Sendable
  work that swift-concurrency-63 already covers.
---

# Swift 6.4 concurrency

Prove isolation and lifetime first (`swift-concurrency-63`). This skill only
covers APIs that shipped in 6.4.

## Procedure

1. Confirm Swift 6.4 (`swift --version`). Stop if the project is on 6.3 or Xcode's `/usr/bin/swift`.
2. Classify the work: cleanup-on-exit, resume-once bridge, Sendable audit, unstructured task, or storing an outcome.
3. Pick the 6.4 tool from the table in [references/concurrency-64.md](references/concurrency-64.md).
4. Compile the smallest example. Treat new warnings on unused throwing `Task { }` as real bugs, not noise.
5. Test success, throw, cancel, and double-resume / drop-without-resume paths.

## Guardrails

- `defer { await … }` still observes cancellation. Wrap teardown in `withTaskCancellationShield` when the work must finish after cancel.
- `withTaskCancellationShield` is for short cleanup. Do not hide a long operation from cancellation.
- Prefer `Continuation` / `withContinuation(of:)` when resume-once is a compile-time invariant. Convert to `CheckedContinuation` only when two escaping callbacks may fire and the library promises exactly one.
- Write `~Sendable` on the type declaration. Do not combine it with `Sendable` on the same type. A subclass may still opt in.
- `_ = Task { try await … }` is allowed but means "ignore failure on purpose." Prefer handling inside the task.
- `await Result { try await … }` is for storing an outcome. Do not wrap every `try await`.

## Completion contract

Report isolation domains, which 6.4 API was chosen and why, cancel/resume proof, and compiler evidence under Swift 6.4.
