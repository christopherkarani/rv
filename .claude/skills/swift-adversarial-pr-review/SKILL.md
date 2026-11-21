---
name: swift-adversarial-pr-review
description: >
  Single-agent adversarial Swift PR / diff review using compiler-enforced best practices
  (correctness, concurrency, API design, maintainability, testability, agent-friendliness).
  Verify project/toolchain support before recommending language features; fix only when
  explicitly permitted. Use for adversarial Swift review, swift-adversarial-pr-review,
  or a best-practices audit of a Swift PR/diff. Do not use for multi-lane orchestration,
  /swift-pr-review, or /multi-agent-swift-pr-review.
---

# Swift PR Review Skill

## Purpose

Review Swift pull requests as an expert Swift engineer.

The goal is not merely to find syntax errors or formatting problems. The goal is to determine whether a change makes the codebase:

- correct
- maintainable
- testable
- composable
- type-safe
- concurrency-safe
- easy for future humans and coding agents to understand
- difficult to misuse
- difficult to put into invalid states

Prefer boring, explicit, compiler-verified Swift over clever abstractions.

The core principle is:

> Prefer designs where incorrect modifications become compiler errors.

Encode invariants using:

- structs
- enums
- associated values
- exhaustive switches
- generic constraints
- protocols
- `some`
- `any` where runtime heterogeneity is intentional
- access control
- actor isolation
- `Sendable`
- typed domain errors
- ownership when ownership is genuinely part of the domain

Prefer deep modules with small, stable interfaces that hide implementation complexity.

Within those modules, prefer explicit, locally visible behavior over:

- runtime indirection
- hidden mutation
- unnecessary type erasure
- reflection
- dynamic lookup
- generated APIs
- custom DSLs
- implicit global state

Do not reward code for being sophisticated.

Reward code for making its invariants obvious.

## Operating Modes

Determine the requested mode before changing code.

### Review-Only Mode

Use when asked to review, inspect, audit, or comment on a PR.

- Do not modify files.
- Report only actionable findings supported by evidence.
- Do not turn optional refactors into merge blockers.
- Do not expand the review into unrelated pre-existing problems unless they are directly made worse by the PR.

### Review-and-Fix Mode

Use only when the user explicitly asks to fix, apply, patch, or implement review findings.

- Review first.
- Fix only confirmed findings in scope.
- Prefer the smallest coherent patch.
- Add or update tests when behavior changes.
- Validate the resulting diff.
- Adversarially re-review the patch after fixing it.

If the user's intent is ambiguous, default to review-only.

---

## Project and Toolchain Gate

Before recommending or applying Swift language features, establish what the repository actually supports.

Inspect relevant sources of truth such as:

- `Package.swift`
- `// swift-tools-version`
- `swiftLanguageModes` / Swift language mode settings
- Xcode project or workspace build settings
- `.swift-version`
- CI configuration
- deployment targets
- package/platform constraints
- repository documentation

Do not recommend a Swift 6.x feature merely because it is a best practice in the abstract.

Verify that the repository's compiler, language mode, platform, and CI environment support it.

Examples that require version/context awareness include:

- typed throws
- `package` access
- strict concurrency behavior
- `@concurrent`
- ownership features such as `borrowing`, `consuming`, and `~Copyable`
- `Span`
- `InlineArray`
- module selectors
- Swift Testing
- Swift 6.4: `Continuation`, `UniqueArray` (Swift module; not `RigidArray`), `Iterable`, `~Sendable`, async `defer`, `withTaskCancellationShield`, `anyAppleOS`, `@diagnose`, Span-safe `@c` wrappers, Swift Build as SwiftPM default

If a newer feature would materially improve the design but the repository cannot use it, report it as an optional future improvement rather than a current defect.

Never "fix" a PR by silently raising the package's Swift tools version, deployment target, language mode, or Xcode requirement unless the task explicitly includes that migration.

### Platform Availability

Compiler support is not the same as runtime platform availability.

When a PR introduces Apple-platform APIs, verify deployment-target compatibility and availability requirements.

Check whether new APIs require:

- `@available`
- `if #available`
- fallback behavior
- platform-conditional compilation

Do not lower deployment compatibility accidentally.

Do not add availability guards when the repository's minimum deployment target already guarantees the API.

---

## Scope Discipline

Review the PR, not the entire history of the repository.

Distinguish:

- defects introduced by the PR
- pre-existing defects exposed by the PR
- unrelated pre-existing issues

A finding is merge-blocking only when the PR introduces it, materially worsens it, or depends on it for correctness.

Do not use a small PR as justification for broad architectural cleanup.

However, if the review reveals a broader architectural issue that is real, recurring, and worth addressing separately, record it as a non-blocking follow-up suggestion for the end of the review.

A broad architectural cleanup suggestion must:

- be clearly separated from PR findings
- not affect the PR verdict unless the current PR depends on the issue for correctness
- describe the recurring architectural problem, not just a preferred style
- explain why addressing it would reduce complexity, coupling, duplication, or maintenance cost
- identify the likely scope or subsystem involved
- recommend handling it in a dedicated follow-up change
- avoid prescribing a large redesign unless the evidence supports it

Examples include:

- repeated leakage of internal state across module boundaries
- multiple shallow abstractions that should become one deeper module
- duplicated lifecycle or concurrency coordination across callers
- repeated type erasure hiding useful type relationships
- several subsystems independently reimplementing the same invariant
- a broad public surface that could be reduced behind a deeper module
- architecture that repeatedly forces unrelated features to modify the same central type

Avoid touching:

- generated files
- vendored dependencies
- checked-in build artifacts
- third-party source

unless the PR intentionally modifies them or the source generator itself is the actual target.

If generated output is wrong, prefer fixing the generator or source definition rather than hand-editing generated code.

---

## Review Workflow

Perform the review in this order.

### 1. Understand the Change

Before judging individual lines:

1. Determine what behavior the PR intends to introduce or modify.
2. Identify the modules and architectural boundaries affected.
3. Identify public or package-visible API changes.
4. Identify state ownership.
5. Identify concurrency boundaries.
6. Identify error boundaries.
7. Identify external side effects.
8. Identify tests that should prove the behavior.

Do not start by commenting on formatting.

Understand the design first.

### Establish the Behavioral Contract

Before proposing fixes, identify what must remain true.

Use evidence from:

- the PR description or issue
- tests
- public API documentation
- call sites
- existing behavior
- compatibility requirements

Distinguish intentional behavior changes from regressions.

Do not "fix" behavior merely because another behavior seems cleaner.

If the intended behavior is genuinely ambiguous and the ambiguity affects correctness, report that uncertainty instead of inventing a contract.

### 2. Review the Diff in Context

Do not review changed lines in isolation.

Inspect surrounding code when needed to understand:

- ownership
- callers
- protocol requirements
- state transitions
- isolation
- lifecycle
- API consistency
- existing abstractions
- tests

Before proposing a new abstraction, search the repository for an existing one.

Before claiming something is unused, search for references.

Before changing an API, inspect its callers.

Determine the actual PR boundary from the environment when possible.

Compare the intended base and head rather than assuming that every local modification belongs to the PR.

Inspect enough surrounding history when necessary to distinguish newly introduced behavior from existing behavior, but do not perform repository-wide archaeology without a concrete reason.

---

## Review Priority

Review issues in this order:

1. Correctness
2. Safety
3. Concurrency
4. Data and state modeling
5. API design
6. Architecture
7. Testability
8. Maintainability
9. Performance
10. Readability
11. Style

Never spend most of the review discussing style while correctness or architectural issues remain.

### Finding Quality and Noise Budget

A review is not better because it contains more comments.

For every potential finding, ask:

1. Is it caused or materially affected by this PR?
2. Can I point to concrete code or behavior?
3. Is there a plausible failure mode or maintenance cost?
4. Would a senior Swift maintainer likely act on it?
5. Is it distinct from another finding?

If not, omit it.

Aggregate repeated instances of the same systemic issue into one finding with representative locations.

Do not flood the review with low-severity observations.

Prefer a few high-confidence findings over many speculative ones.

Do not report formatting, naming, or micro-style comments when automated formatting/linting already owns the rule unless the issue materially harms API clarity.

### Defaults Are Not Laws

The recommendations in this skill are defaults, not mechanical rewrite rules.

Do not report a finding solely because code uses:

- a class instead of a struct
- `any` instead of `some`
- a concrete dependency instead of a protocol
- a lock instead of an actor
- XCTest instead of Swift Testing
- inheritance instead of composition
- a result builder, macro, property wrapper, or type erasure

A finding requires a concrete downside in the actual code under review.

Repository conventions, framework constraints, interoperability, ABI requirements, performance evidence, ergonomics, and domain semantics may justify a different choice.

When an existing design is clear, correct, tested, and consistent with the repository, do not churn it merely to match this skill's preferred style.

---

# Swift Best Practices

## Value Semantics First

Prefer `struct` unless the type requires:

- stable identity
- shared mutable state
- inheritance
- reference semantics
- framework-required class semantics

Question newly introduced classes.

Prefer:

```swift
struct Configuration {
    let model: Model
    let timeout: Duration
}
```

over mutable reference objects where identity provides no value.

If a class is not designed for inheritance, prefer:

```swift
final class Runtime {
}
```

Do not introduce inheritance when composition can model the relationship more clearly.

Do not mechanically convert classes to structs.

Reference semantics may be intentional for:

- identity
- graph nodes
- shared caches
- observation frameworks
- Objective-C interoperability
- lifecycle ownership
- expensive copy-on-write tradeoffs

A class-vs-struct comment is actionable only when the current semantics create a real correctness, ownership, or maintainability problem.

---

## Model State with Enums

Look aggressively for invalid state representations.

Flag combinations such as:

```swift
var isRunning: Bool
var isFinished: Bool
var error: Error?
var result: Result?
```

when the domain actually represents mutually exclusive states.

Prefer:

```swift
enum ExecutionState {
    case idle
    case running
    case completed(Output)
    case failed(ExecutionError)
}
```

Use associated values to keep data attached to the state where it is valid.

Prefer exhaustive `switch` statements when every state matters.

Avoid `default` in switches over closed domain enums when explicit cases provide better compiler assistance during future changes.

A new enum case should ideally cause relevant code to stop compiling until the new state is handled.

---

## Make Invalid States Unrepresentable

Look for types that permit impossible combinations.

Bad:

```swift
struct Request {
    var authenticated: Bool
    var token: String?
}
```

Prefer:

```swift
enum Authentication {
    case anonymous
    case authenticated(Token)
}
```

Prefer semantic types such as:

- `NonEmptyArray`
- `ValidatedConfiguration`
- `ParsedCommand`
- `AuthorizedRequest`

when the type can guarantee properties that would otherwise need repeated runtime validation.

Do not create wrapper types without meaningful invariants.

---

## Protocol Design

Protocols should describe meaningful capabilities or architectural boundaries.

Good:

```swift
protocol Clock {
    func now() -> Instant
}
```

Good:

```swift
protocol Tool {
    associatedtype Input: Sendable
    associatedtype Output: Sendable

    func execute(_ input: Input) async throws -> Output
}
```

Question protocols that:

- have only one implementation with no testing or architectural reason
- mirror every method of a concrete implementation
- exist only because dependency injection supposedly requires protocols
- combine unrelated responsibilities
- contain large numbers of optional or defaulted requirements
- inherit from many unrelated protocols

Avoid Java-style abstraction pyramids such as:

```text
Foo
FooProtocol
FooService
FooServiceProtocol
FooServiceImpl
```

unless every layer has a real architectural purpose.

Prefer deep modules with small interfaces and substantial hidden implementation.

---

## Generics

Use generics when behavior genuinely depends on type relationships.

Prefer:

```swift
func execute<T: Tool>(
    _ tool: T,
    input: T.Input
) async throws -> T.Output
```

over:

```swift
func execute(
    tool: Any,
    input: Any
) async throws -> Any
```

Question generic abstractions that:

- have only one concrete use
- expose implementation details
- make signatures significantly harder to understand
- exist only to avoid a small amount of duplication

Do not introduce generics merely to make code appear reusable.

---

## `some` vs `any`

Prefer `some Protocol` or generic parameters when the concrete type does not need to vary dynamically.

Example:

```swift
func execute(_ tool: some Tool)
```

Use `any Protocol` when runtime heterogeneity is intentional.

Example:

```swift
let tools: [any Tool]
```

Question unnecessary existential erasure.

Ask:

- Does this value genuinely need to hold multiple runtime types?
- Could this API preserve its concrete type?
- Is type erasure hiding useful compiler information?

Do not mechanically replace every `any` with generics.

Dynamic boundaries often legitimately require existentials.

Do not cite existential boxing or dynamic dispatch as a performance defect without evidence that the code is performance-sensitive.

Prefer clarity over speculative generic specialization.

---

## Access Control

Use the narrowest practical access level.

Prefer:

- `private`
- `internal`
- `package`
- `public`

according to the real intended boundary.

Question newly introduced `public` declarations.

Never make something `public` simply to make compilation or tests easier.

For SwiftPM packages, consider `package` when multiple package modules need access but consumers should not.

Access control is part of architecture.

Treat unnecessary visibility as increased coupling.

---

# Concurrency

Treat concurrency correctness as a first-class review concern.

For every asynchronous change, determine:

1. Which executor or actor owns mutable state?
2. Is the state shared?
3. Are transferred values `Sendable`?
4. Can operations execute concurrently?
5. Can tasks outlive the object that created them?
6. Is cancellation propagated?
7. Is task lifetime structured?
8. Are actor boundaries explicit enough?
9. Is ordering required?
10. Could a race, reentrancy issue, or stale state occur?

---

## Structured Concurrency

Prefer structured concurrency.

Prefer:

```swift
async let first = loadFirst()
async let second = loadSecond()

let result = try await (first, second)
```

or task groups when child tasks belong to an operation.

Question:

```swift
Task {
    ...
}
```

when task lifetime is unclear.

Be especially suspicious of:

```swift
Task.detached {
}
```

Require a specific reason for detached execution.

A detached task should not be used merely to silence actor isolation errors.

Do not flag `Task { ... }` simply because it is unstructured.

Instead verify:

- who owns its lifetime
- whether cancellation is propagated or intentionally independent
- whether inherited actor context is intended
- whether errors are observed
- whether the task can leak or outlive required state

---

## Actors

Use actors for genuinely shared mutable state that requires serialization.

Good:

```swift
actor Registry {
    private var values: [ID: Value] = [:]
}
```

Do not introduce actors simply because a type has async methods.

Do not flag a lock or other synchronization primitive merely because an actor exists as an alternative. Locks can be appropriate for small synchronous critical sections, low-level code, or APIs that cannot become async.

Review the actual synchronization invariant.

Review actor code for reentrancy.

Remember that state can change across `await`.

Do not assume actor state observed before an `await` remains unchanged afterward.

Flag patterns where logic relies on that assumption.

---

## `Sendable`

Prefer values crossing concurrency boundaries to conform naturally to `Sendable`.

Inspect captured values in `@Sendable` closures.

Treat these as warning signs:

```swift
@unchecked Sendable
nonisolated(unsafe)
```

They are not automatically wrong.

They require a clear, defensible invariant.

If `@unchecked Sendable` is introduced, verify:

- why automatic checking is insufficient
- whether underlying state is actually synchronized or immutable
- whether the guarantee can be represented more safely
- whether tests cover synchronization behavior

Do not use unsafe annotations merely to satisfy the compiler.

---

## Main Actor Isolation

Use `@MainActor` for state or behavior that genuinely belongs to the UI or main actor.

Do not move unrelated work onto the main actor to eliminate concurrency diagnostics.

Question broad annotations such as:

```swift
@MainActor
final class EntireSubsystem {
}
```

when only a small portion actually requires main-actor isolation.

Prefer the narrowest correct isolation boundary.

---

## `@concurrent`

Use `@concurrent` when execution should intentionally occur concurrently and doing so communicates an important execution property.

Do not add concurrency purely as an optimization without:

- evidence it is needed
- clear ownership
- cancellation semantics
- tests where appropriate

Concurrency increases the number of possible program states.

It must buy something.

---

# Error Modeling

Prefer domain-specific errors for meaningful domain failures.

Example:

```swift
enum CompilationError: Error {
    case invalidGraph
    case unresolvedDependency(NodeID)
    case cycleDetected([NodeID])
}
```

Use typed throws when the failure domain is intentionally closed and callers benefit from knowing it:

```swift
func compile(_ graph: Graph) throws(CompilationError) -> Program
```

Do not force typed throws onto infrastructure APIs whose error surface naturally evolves or wraps many external systems.

Avoid stringly typed errors when a meaningful Swift error type can model the domain.

Check that errors preserve useful context.

Do not silently swallow errors.

Question:

```swift
try?
```

when failure matters.

Question:

```swift
catch {
}
```

almost always.

---

# Optionals and Casts

Use optionals to represent actual absence.

Do not use `nil` as an undocumented state machine.

Prefer:

```swift
guard let configuration else {
    throw ConfigurationError.missing
}
```

when continuing without the value makes no sense.

Avoid force unwraps:

```swift
value!
```

unless an invariant makes failure impossible and that invariant is obvious and stable.

Question force casts:

```swift
as!
```

Prefer compile-time type relationships or safe casts.

If an invariant is structural, encode it structurally.

---

# Mutation

Minimize mutation scope.

Prefer `let` unless mutation is required.

Keep mutable state close to the code responsible for maintaining its invariants.

Question mutable public properties.

Bad:

```swift
runtime.tasks[id] = task
```

Prefer:

```swift
runtime.register(task)
```

when the operation must enforce invariants.

---

# Dependency Injection

Prefer initializer injection for required dependencies.

```swift
struct Runner {
    let clock: any Clock
    let executor: any Executor
}
```

Avoid hidden dependencies through:

- globals
- service locators
- singleton access
- custom property-wrapper injection
- ambient mutable state

Dependencies should usually be visible from constructors or function parameters.

Do not create protocols solely to mock trivial pure types.

---

# Global State

Treat mutable global and static state as suspicious.

Ask:

- Who owns it?
- Who can mutate it?
- Is access synchronized?
- Can tests isolate it?
- Does it create ordering dependencies?

Prefer explicitly owned state.

---

# Extensions

Use extensions for:

- protocol conformances
- clearly distinct capabilities
- platform-specific behavior
- logical organization

Avoid scattering one type's core behavior across many unrelated files.

Code locality matters.

A developer or coding agent should be able to discover the important behavior of a type without repository-wide archaeology.

---

# Property Wrappers

Standard framework wrappers are acceptable when used idiomatically.

Treat custom property wrappers cautiously.

Question wrappers that hide:

- dependency lookup
- persistence
- network access
- mutation
- synchronization
- caching
- validation
- lifecycle behavior

Important behavior should remain visible.

Avoid replacing understandable Swift with annotation-driven magic.

---

# Macros

Macros are acceptable when they remove genuinely mechanical boilerplate without hiding important architecture.

Be cautious when macros generate:

- public APIs
- control flow
- state management
- dependency injection
- persistence behavior
- concurrency behavior
- significant domain behavior

Ask whether a developer can understand the type from the source file without mentally expanding the macro.

Prefer ordinary Swift when the abstraction would otherwise hide important behavior.

Testing macros such as `#expect` and `#require` are encouraged where appropriate.

---

# Result Builders

Use result builders for genuinely declarative APIs such as UI or intentionally designed DSLs.

Do not use result builders to make ordinary imperative application logic look declarative.

Question custom builders that obscure:

- control flow
- ordering
- error propagation
- concurrency
- mutation
- execution semantics

Explicit code is usually easier to modify safely.

---

# Custom Operators

Avoid introducing custom operators for application or domain behavior.

Bad:

```swift
agent >>> tool
workflow ~> executor
```

Prefer:

```swift
agent.execute(using: tool)
workflow.run(on: executor)
```

Operators should be reserved for domains where the notation is genuinely conventional and improves understanding.

---

# Dynamic Language Features

Strongly discourage:

```swift
@dynamicMemberLookup
@dynamicCallable
```

outside interoperability or specialized framework boundaries.

They weaken source discoverability and compiler-assisted navigation.

Prefer explicit APIs.

---

# Type Erasure

Question wrappers such as:

```swift
AnyTool
AnyExecutor
AnyRepository
```

Determine whether type erasure is genuinely required.

Use it at dynamic storage or module boundaries where heterogeneous values must share a representation.

Do not erase types prematurely.

Preserving types gives the compiler and maintainers more information.

---

# Ownership Features

Swift ownership features such as:

```swift
borrowing
consuming
~Copyable
```

are useful when ownership itself is part of the domain.

Appropriate examples include:

- file descriptors
- sockets
- locks
- transaction handles
- native handles
- unique resources
- performance-sensitive buffers

Do not introduce ownership complexity into ordinary domain models without a concrete reason.

When reviewing ownership code, verify that the implementation actually benefits from the stronger invariant.

---

# Low-Level Swift

Features such as:

- `Span`
- `InlineArray`
- unsafe pointers
- manual memory management
- C/C++ interop

require additional scrutiny.

Verify:

- bounds
- lifetime
- aliasing
- ownership
- initialization
- deinitialization
- pointer validity
- thread safety

Prefer safe Swift abstractions whenever their performance is sufficient.

Unsafe code should be small and encapsulated behind a safe API.

---

# Library Evolution and ABI-Sensitive Code

When reviewing public libraries or binary-distributed frameworks, inspect features that affect source or ABI evolution.

Treat these as deliberate design decisions:

- `@frozen`
- `@inlinable`
- `@usableFromInline`
- public enum exhaustiveness
- public protocol requirements
- public generic constraints
- `open` classes and methods

Do not add these attributes for performance or convenience without understanding their long-term compatibility cost.

Be especially cautious about adding requirements to public protocols or cases to frozen public enums.

For application-internal code where ABI stability is irrelevant, do not manufacture ABI concerns.

---

# API Design

A good API should make the correct operation obvious.

Prefer:

```swift
store.save(document)
```

over:

```swift
store.perform(
    operation: .save,
    payload: document,
    options: nil
)
```

unless the generalized operation is genuinely needed.

Check argument labels.

Swift APIs should read naturally at call sites.

Prefer semantic types over primitive parameters.

Bad:

```swift
run(true, 10, "fast")
```

Better:

```swift
run(
    inParallel: true,
    retryLimit: 10,
    mode: .fast
)
```

Use a configuration type when those values form one cohesive concept.

---

# Deep Modules

Strongly prefer deep modules.

A deep module exposes a small, stable interface while hiding substantial implementation complexity behind that boundary.

Deep modules are a primary maintainability goal because they reduce the amount of code, state, and behavior a caller must understand in order to use a subsystem correctly.

When reviewing architecture, actively look for opportunities to:

- reduce public surface area
- move invariants behind module boundaries
- hide coordination and bookkeeping
- centralize lifecycle management
- centralize concurrency and synchronization
- centralize validation
- centralize error translation
- keep callers dependent on capabilities rather than implementation details
- make common operations possible through a small number of high-level entry points

Prefer:

```swift
try await executor.run(plan)
```

where `Executor` owns scheduling, retries, cancellation, tool dispatch, and result aggregation,

over requiring callers to understand and manually coordinate each of those concerns.

A good deep module should make complicated implementation behavior look simple from the outside.

## Deep vs Shallow Modules

Flag shallow abstractions that add names or indirection without hiding meaningful complexity.

Bad:

```swift
func fetchUser() async throws -> User {
    try await api.fetchUser()
}
```

when the wrapper adds no policy, invariant, translation, ownership, lifecycle, or architectural boundary.

Similarly, be suspicious of layers such as:

```text
Foo
FooService
FooManager
FooCoordinator
FooRepository
```

when each layer merely forwards calls to the next.

The presence of multiple layers does not make a module deep.

Depth comes from a high ratio of hidden implementation complexity to exposed interface complexity.

## Review Questions for Module Depth

Ask:

- Can callers accomplish common tasks through a smaller interface?
- Are callers forced to know about internal sequencing or bookkeeping?
- Are invariants enforced inside the module or repeated across callers?
- Is internal state leaking through public properties or low-level methods?
- Does the module expose implementation details that could be private?
- Can multiple low-level operations be composed behind one meaningful domain operation?
- Would changing the implementation require modifying many callers?
- Does the module own enough responsibility to justify its abstraction boundary?

Prefer moving complexity inward when doing so produces a clearer and more stable interface.

## Deep Modules and Agent-Maintained Code

Deep modules are especially valuable for coding agents.

They reduce:

- repository-wide context requirements
- number of symbols an agent must reason about
- blast radius of modifications
- duplicated invariant handling
- accidental coupling
- opportunities for partially correct changes

A future coding agent should be able to understand and modify one subsystem without loading the entire repository into context.

Favor boundaries where the compiler and access control prevent callers from depending on implementation details.

## Avoid Artificial Depth

Do not create complexity merely to hide it.

Do not add:

- unnecessary protocols
- forwarding layers
- factories with one implementation
- wrappers around trivial operations
- generic indirection without real type relationships

solely to make a module appear deep.

A deep module should remove complexity from its callers, not move simple code into a larger abstraction hierarchy.

Every abstraction must still earn its existence, but when a meaningful abstraction exists, prefer making it deep rather than exposing its internal machinery.

---

# Composition

Prefer composing independent behaviors over building large coordinators.

Look for classes that accumulate unrelated responsibilities.

Signs include:

- many injected dependencies
- many unrelated methods
- vague names such as `Manager`, `Helper`, `Service`, or `Coordinator`
- state from multiple domains
- frequent changes for unrelated features

Recommend extracting cohesive concepts, not arbitrarily splitting files.

---

# Testability

Every behavior change should be testable without unnecessary global infrastructure.

Prefer deterministic dependencies for:

- time
- randomness
- IDs
- networking
- filesystem access
- external processes

Prefer testing observable behavior over implementation details.

---

# Test Review

Verify tests cover:

## Success Paths

The intended operation works.

## Failure Paths

Meaningful failures are tested.

## Boundary Conditions

Examples:

- empty collections
- first or last element
- zero
- maximum values
- missing values
- malformed values

## State Transitions

State machines test valid transitions and rejected invalid transitions.

## Concurrency

Where applicable, test:

- cancellation
- overlapping requests
- actor behavior
- ordering assumptions
- duplicate execution
- stale results

## Regression

Bug fixes should usually contain a test that would fail before the fix.

---

# Test Integrity

Tests are evidence, not obstacles.

In review-and-fix mode, never make a failing implementation "pass" by weakening the test unless the test is demonstrably incorrect.

Treat these changes as high scrutiny:

- deleting assertions
- broadening expected values
- increasing timing tolerances without cause
- replacing deterministic checks with sleeps/retries
- marking tests skipped or disabled
- removing regression tests
- changing expected errors to accept generic failure

When a test must change because the product contract intentionally changed, make that relationship explicit.

Prefer adding a regression test that fails before a bug fix and passes after it.

---

# Swift Testing

Use the repository's established test framework unless the task includes a testing migration.

Swift Testing is appropriate when supported by the repository and toolchain:

```swift
@Test
func compilationFailsForCycles() throws {
    #expect(...)
}
```

Use `#require` when subsequent assertions depend on a condition or unwrapped value.

Do not rewrite healthy XCTest suites into Swift Testing as drive-by cleanup.

Keep tests:

- deterministic
- isolated
- readable
- behavior-oriented

Avoid sleeping in tests to wait for asynchronous behavior.

Prefer synchronization through actual task completion or controllable test dependencies.

Treat snapshot/golden-file updates as behavior changes, not automatic fixes.

Inspect why output changed before accepting regenerated fixtures.

---

# ARC, Captures, and Lifetime

Review ownership relationships created by closures, delegates, tasks, streams, and callbacks.

Look for real retain cycles, especially where:

- `self` owns an escaping closure that captures `self`
- an object stores a task whose closure strongly captures that object
- delegate ownership is accidentally strong
- stream/observer cleanup is tied to deinitialization that can never occur

Do not demand `[weak self]` mechanically.

Weak capture can itself introduce incorrect behavior by silently dropping required work.

Choose strong, weak, or unowned capture based on the actual ownership contract.

For long-lived tasks and streams, verify termination and cleanup paths.

---

# Cancellation

Async APIs should respect cancellation when their work can meaningfully be cancelled.

Check long-running loops and expensive operations.

Consider:

```swift
try Task.checkCancellation()
```

where natural suspension points do not provide sufficient cancellation behavior.

Do not catch and silently discard `CancellationError`.

Cancellation is part of API semantics.

---

# Resource Lifetime

Review resources such as:

- tasks
- file handles
- streams
- continuations
- observers
- subscriptions
- sockets
- processes

Verify they have clear ownership and cleanup.

Look for leaks caused by long-lived closures capturing objects.

Question `[weak self]` used mechanically.

Use weak references because the ownership graph requires them, not because every closure should be weak.

For `AsyncStream` / `AsyncThrowingStream`, inspect:

- continuation ownership
- termination handling
- cancellation behavior
- producer cleanup
- buffering policy when relevant

---

# Continuations

Treat:

```swift
withCheckedContinuation
withCheckedThrowingContinuation
```

carefully.

Verify every execution path resumes exactly once.

On Swift 6.4, prefer `Continuation` / `withContinuation(of:)` when resume-once is a compile-time invariant. Keep `CheckedContinuation` when two escaping callbacks share the handle. Prefer checked continuations over unsafe continuations unless measurements justify otherwise.

Do not use continuations when an existing async API already solves the problem.

---

# Performance

Do not perform speculative micro-optimization.

Review performance when the change affects:

- hot loops
- large collections
- parsing
- serialization
- memory-heavy operations
- repeated allocations
- task creation
- database access
- network calls

Prioritize algorithmic improvements over clever syntax.

Watch for accidental:

- O(n²) loops
- repeated linear searches
- repeated sorting
- unnecessary copying
- repeated parsing

Do not trade substantial maintainability for theoretical gains.

---

# Naming

Names should communicate domain meaning.

Avoid vague names such as:

- `Manager`
- `Helper`
- `Utils`
- `Stuff`
- `Handler`
- `Data`
- `Info`
- `Processor`

unless the surrounding domain makes their meaning clear.

Prefer names such as:

- `ToolRegistry`
- `ExecutionPlanner`
- `DependencyGraph`
- `ProcessExecutor`

Names should describe responsibility rather than implementation mechanics.

---

# Comments

Comments should explain:

- why
- invariants
- non-obvious tradeoffs
- external constraints
- safety assumptions

Avoid comments that narrate obvious code.

Bad:

```swift
// Increment count
count += 1
```

Good:

```swift
// Reserve zero for values originating outside this process.
nextID += 1
```

If complicated code needs a long comment explaining what it does, first consider whether the code itself can become clearer.

---

# Documentation

Public APIs should document behavior that cannot be inferred from their type signature.

Document:

- invariants
- ownership
- threading or isolation expectations
- cancellation
- error semantics
- side effects
- ordering guarantees

Do not demand documentation for obvious private implementation details.

---

# Agent Friendliness

Review explicitly for whether another coding agent could safely modify this code later.

Prefer code where:

- symbol definitions are easy to locate
- behavior is locally visible
- types carry semantic information
- dependencies are explicit
- compiler diagnostics guide refactors
- state transitions are explicit
- APIs have narrow responsibilities
- side effects occur at recognizable boundaries

Flag designs requiring broad implicit context to understand.

Examples include:

- hidden service locators
- runtime registration
- string-based dispatch
- reflection
- annotation-generated behavior
- dynamic member lookup
- uncontrolled globals
- custom DSL semantics
- excessive type erasure

The source code should be a reliable description of runtime behavior.

---

# Common Agent-Generated Code Smells

## Unnecessary Abstraction

Examples:

- protocol for every class
- wrapper around every dependency
- factories with one implementation
- generic abstraction used once
- tiny methods forwarding directly to another object

Remove abstraction that does not establish a meaningful boundary.

## Defensive Noise

Question guards or fallbacks added without understanding whether failure should actually be impossible.

Do not silently hide invalid states.

## Public for Convenience

Agents sometimes increase visibility to make tests or modules compile.

Reject this unless API exposure is intentional.

## Error Suppression

Watch for:

```swift
try?
try!
catch {}
```

used to make compilation or tests pass.

Also watch for replacing a specific error with a generic error merely to simplify type constraints or tests.

Preserve diagnostic context that callers or operators rely on.

## Concurrency Escape Hatches

Watch for:

```swift
Task.detached
@unchecked Sendable
nonisolated(unsafe)
```

used to bypass compiler diagnostics.

## Duplicate Architecture

Search before accepting a newly introduced:

- Repository
- Store
- Client
- Executor
- Registry
- Factory
- Configuration
- Error type

The repository may already contain the appropriate abstraction.

## Premature Generalization

Prefer the smallest abstraction that cleanly supports known requirements.

Do not solve hypothetical future requirements without evidence.

---

# Security Review

When relevant, inspect:

- command execution
- shell interpolation
- path handling
- untrusted input
- network requests
- authentication
- authorization
- credential storage
- serialization
- deserialization
- URL handling
- file permissions

Never interpolate untrusted values directly into shell commands.

Prefer typed argument arrays and safe process APIs.

Validate boundaries where untrusted data enters trusted domain code.

---

# PR Scope

Check whether the PR contains unrelated changes.

A good PR should have a coherent reason to exist.

Flag substantial:

- drive-by refactors
- dependency upgrades
- formatting churn
- renames
- architecture changes

when unrelated to the requested behavior and when they increase review risk.

Do not complain about tiny adjacent improvements that clearly reduce complexity.

Do not upgrade dependencies, package tools versions, deployment targets, or build settings as incidental cleanup.

If a dependency change is part of the PR, inspect:

- why it is needed
- API/source compatibility
- platform support
- lockfile/resolution changes
- whether the diff pulls in unrelated transitive changes

---

# Backward Compatibility

For public or package APIs, inspect whether the change breaks:

- callers
- source compatibility
- serialized data
- persisted state
- protocol conformances
- configuration formats
- command-line interfaces

Breaking changes can be valid.

They must be deliberate.

Also inspect semantic compatibility: code can remain source-compatible while changing ordering, threading, cancellation, persistence, error, or lifecycle behavior in ways callers rely on.

Do not reduce compatibility review to whether the code still compiles.

---

# Review Severity

Classify findings as follows.

## P0: Critical

Must fix immediately.

Examples:

- exploitable security issue
- data corruption
- guaranteed crash in normal usage
- severe concurrency race
- destructive unintended behavior

## P1: High

Must fix before merge.

Examples:

- incorrect behavior
- broken invariant
- race condition
- incorrect actor isolation
- resource leak
- significant API contract violation
- missing essential failure handling

## P2: Medium

Should normally fix before merge.

Examples:

- poor state representation
- unnecessary unsafe annotation
- major test gap
- problematic abstraction
- substantial maintainability problem
- hidden dependency

## P3: Low

Worth improving but not merge-blocking.

Examples:

- naming
- localized duplication
- minor readability improvement
- small API refinement

Do not inflate severity.

Style preferences are not P1 issues.

---

# Evidence Requirement

Every review finding must contain:

1. The concrete location.
2. The behavior or design being criticized.
3. Why it matters.
4. A realistic failure mode or maintenance cost.
5. A suggested correction.

Do not produce vague comments such as:

> This could be cleaner.

Instead say:

> `ExecutionContext` exposes `tasks` as mutable state, allowing callers to bypass the registry's uniqueness invariant. Make the collection private and expose `register(_:)` so duplicate-ID validation remains centralized.

Do not report hypothetical issues without a plausible path to failure.

Assign severity from impact, not confidence.

If confidence is not high enough to assert a defect, either gather more evidence or omit the finding.

Do not convert questions such as "could this race?" into findings until the relevant isolation, ownership, and call paths have been inspected.

For architectural findings, identify the concrete coupling or invariant being harmed rather than appealing to a preferred pattern.

When producing PR comments, anchor findings to the smallest relevant changed location when possible.

If the root cause is pre-existing but the PR newly depends on it, state that explicitly rather than pretending the PR introduced the code.

---

# Avoid False Positives

Before reporting a finding:

- verify the relevant code
- inspect the surrounding implementation
- inspect call sites when necessary
- check existing tests
- consider whether Swift's compiler already guarantees the property
- distinguish personal preference from correctness

Do not criticize code merely because another design is possible.

Only raise a finding when the alternative materially improves correctness, safety, maintainability, testability, or clarity.

---

# Compiler Diagnostics Are Evidence, Not Instructions

Use compiler diagnostics, strict concurrency diagnostics, warnings, and tests as high-value evidence.

Do not mechanically silence them.

Never resolve a diagnostic merely by reaching for:

- `@unchecked Sendable`
- `nonisolated(unsafe)`
- `Task.detached`
- force casts
- force unwraps
- broader `@MainActor`
- wider access control
- suppressed errors

First determine the invariant the compiler is protecting and repair the design where practical.

If an escape hatch is truly required, document the invariant that makes it safe and keep its scope as narrow as possible.

---

# Fixing Issues

In review-and-fix mode, fix confirmed issues rather than merely describing them.

For each fix:

1. Make the smallest coherent change.
2. Preserve behavior outside the intended fix.
3. Preserve existing architectural conventions unless those conventions are the problem.
4. Avoid unrelated renames, formatting churn, and cleanup.
5. Add or update tests when behavior or an invariant changes.
6. Compile using the repository's supported toolchain.
7. Run the most relevant tests first, then broader tests when practical.
8. Run formatting or linting if configured.
9. Inspect the final diff for accidental scope expansion.
10. Re-review the resulting diff adversarially.

Do not fix a local smell by introducing a larger abstraction unless justified.

Do not change public API shape, supported platforms, package tools version, or dependency versions merely to make a local implementation easier unless the requested change requires it.

Do not weaken production encapsulation solely for tests.

Before widening access control or exposing internal state for testing, prefer testing through behavior or using existing package/testability mechanisms.

Do not add production-only hooks whose sole purpose is satisfying a test unless the repository explicitly uses that pattern and the tradeoff is justified.

---

# Validation

Use the project's actual tooling.

Check:

- `Package.swift`
- repository documentation
- CI configuration
- `Makefile`
- scripts
- Xcode project or workspace configuration

The CI configuration is often the best source of truth for required validation.

Typical commands may include:

```bash
swift build
swift test
```

or Xcode-specific commands.

Do not assume these commands are correct if the repository defines its own workflow.

Prefer non-destructive validation.

Do not run commands that publish, deploy, release, push, rewrite history, delete data, mutate production infrastructure, or alter external services merely to validate a PR.

If full validation requires unavailable credentials, external services, unsupported platforms, or destructive actions, report the limitation instead of pretending validation succeeded.

Passing tests and a successful build are necessary evidence, not proof that the PR is correct.

Conversely, a validation failure caused by an unrelated environment or pre-existing issue is not automatically a defect in the PR. Separate PR-caused failures from environmental failures when evidence permits.

---

# Adversarial Re-Review

After fixing issues, review the resulting change again from a fresh perspective.

Ask:

- What assumption is still implicit?
- What input breaks this?
- What happens under cancellation?
- What happens concurrently?
- What state combination should be impossible?
- What happens if a dependency fails?
- Does this API leak unnecessary implementation details?
- Could this code be simpler?
- Did the fix introduce another problem?
- Would a new contributor understand the invariant?
- Would another coding agent safely modify this six months from now?
- Did I change the intended behavior while "cleaning up" the implementation?
- Did I weaken a test instead of fixing the bug?
- Did I add abstraction only because this skill prefers it?
- Am I blaming the PR for a pre-existing issue?
- Does this work on every deployment target the repository claims to support?
- Did I validate lifetime and cancellation, not just compilation?
- Did I notice a recurring architectural pattern that should be suggested separately rather than forced into this PR?

Repeat until no material issues remain.

---

# Final Review Format

Output:

## Verdict

One of:

- `APPROVE`
- `REQUEST CHANGES`
- `COMMENT`

Then provide a concise explanation.

## Findings

Sort findings by severity.

For each finding:

```text
[P1] Short descriptive title

Location: path/to/File.swift:line

Problem:
Explain the concrete issue.

Why it matters:
Explain the realistic impact.

Recommended fix:
Explain the smallest correct change.
```

Do not include a finding unless it is actionable.

## Positive Design Notes

Mention only genuinely valuable decisions that should be preserved.

Do not add generic praise.

If there are no actionable findings, say so directly. Do not invent P3 comments to make the review look substantial.

## Architectural Follow-Up

Include this section only when the review uncovered a meaningful broader cleanup opportunity that should not be part of the current PR.

Format:

```text
Architectural follow-up:
<concise title>

Observed pattern:
Describe the recurring architectural issue and where it appears.

Why it matters:
Explain the maintainability, coupling, testability, or agent-context cost.

Suggested direction:
Describe the architectural direction at a high level. Prefer deeper modules, smaller interfaces, stronger invariants, or clearer ownership where appropriate.

Recommended scope:
Explain what should be handled in a dedicated follow-up PR or design task.
```

Rules:

- Keep this non-blocking by default.
- Do not duplicate ordinary PR findings here.
- Do not use this section for speculative redesign ideas.
- Do not add it merely because the codebase is imperfect.
- Prefer one strong architectural follow-up over a list of vague cleanup ideas.
- If no meaningful broad cleanup is evident, omit the section entirely.

## Validation

Report what you actually validated:

```text
Build: PASS / FAIL / NOT RUN
Tests: PASS / FAIL / NOT RUN
Lint: PASS / FAIL / NOT RUN
```

Never claim a command ran if it did not run.

## Remaining Risks

List only meaningful uncertainties that could not be validated.

If none:

```text
None identified.
```

---

# Approval Standard

`REQUEST CHANGES` only when at least one P0, P1, or clearly merge-blocking P2 finding remains.

Use `COMMENT` when findings are useful but non-blocking.

Use `APPROVE` when no material issue remains, even if optional improvements are possible.

Approve the PR only when you believe:

- behavior is correct
- important invariants are encoded clearly
- concurrency is safe
- ownership is understandable
- APIs have appropriate boundaries
- error handling is intentional
- tests cover meaningful behavior
- unnecessary abstraction has not been introduced
- unsafe escape hatches are justified
- another engineer can maintain the code
- another coding agent can modify the code without needing large amounts of hidden context

The best Swift is not the Swift using the most language features.

The best Swift uses the type system, compiler, ownership model, and concurrency model to make correct code easy to write and incorrect code difficult to express.
