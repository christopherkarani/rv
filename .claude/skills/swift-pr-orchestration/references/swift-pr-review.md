# Swift PR Review Checklist

Load this reference for every Swift PR review; skip sections that are demonstrably irrelevant and state why.

## API and compatibility

- Is the package’s current version before the documented breaking boundary?
- Does the change remove or alter a public type, initializer, protocol requirement, typealias, enum case, Codable key, or overload?
- Are deprecated shims intentionally retained, and do their forwarding/default implementations preserve historical behavior?
- Do DocC, README, guides, API catalogs, and source signatures agree?

## Concurrency and cancellation

Ask:

- What happens if cancellation arrives before the operation, after a callback, during a sleep, after a detached task starts, or while an actor state transition is in flight?
- Does every value crossing an actor/task boundary satisfy the intended `Sendable` contract?
- Are nonisolated methods actually safe, and are `@unchecked Sendable`, locks, continuations, and task groups justified?
- Can a loser task, callback, stream, or retry continue mutating state after the owner has finished?

## State, persistence, and determinism

- Are empty, nil, negative, overflow, retry-exhaustion, repeat-limit, and resume cases defined?
- Are persisted checkpoint/run signatures normalized across old and new spellings?
- Does Codable decode historical data and encode a compatible representation?
- Are injected clocks, random sources, callbacks, and test doubles deterministic without changing production semantics?

## Platform and package graph

- Does the code compile on every declared platform, including iOS where `Foundation.Process` or unavailable frameworks may differ?
- Are SwiftPM products, traits, macros, and remote dependencies linked only where intended?
- Does the test command exercise the same trait/platform path as the changed product?

## Testing evidence

Require a focused regression test for each P0/P1 behavior. Prefer tests at the storage/serialization/actor boundary, not only helper-level tests. Run the project’s canonical gate after focused checks and classify environment/baseline failures separately.

## Finding format

For each actionable finding, report:

`P0/P1/P2/P3 — file:line — scenario — observed or reasoned failure — minimal fix — regression test.`
