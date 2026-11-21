---
name: swift-type-system-architecture
description: Explore a Swift codebase for high-leverage opportunities to use generics, protocols, associated types, some/any, enums, value types, and related type-system features to improve architecture. Surface only cases where stronger typing removes runtime ambiguity, invalid states, casts, duplication, or caller knowledge. Write the HTML report, then auto-execute Strong candidates via create-specification and implement-spec (ticket PRs, size-routed review, worktree cleanup) unless --explore-only. Do not wait for the user to pick a candidate.
disable-model-invocation: true
---

# Swift Type-System Architecture

Explore a Swift codebase and identify places where Swift's type system can carry more of the architecture.

This skill is intentionally biased toward expert-level use of:

- generics
- generic constraints
- protocols
- associated types
- primary associated types
- opaque types (`some`)
- existentials (`any`)
- constrained existentials
- enums
- associated values
- value semantics
- conditional conformances
- semantic/newtype wrappers
- typed errors
- `Sendable`
- ownership features when justified

The goal is **not** to maximize generic code.

The goal is to replace runtime ambiguity, invalid states, casts, duplicated coordination, and weakly expressed relationships with compiler-checked design.

Core principle:

> Use generics to preserve relationships, protocols to define capabilities, enums to close state spaces, value types to make data flow explicit, `some` to hide concrete types while preserving identity, and `any` only where runtime heterogeneity is intentional.

A sophisticated generic design is only good when it makes the system easier to reason about.

---

# Non-Negotiable Rule

Do not recommend a type-system refactor merely because it is more "Swifty."

Every recommendation must eliminate or materially reduce at least one of:

- runtime casts
- `Any` / `AnyObject`
- stringly typed state
- invalid state combinations
- duplicated type checks
- duplicated protocol plumbing
- repeated coordination logic caused by weak type relationships
- public API ambiguity
- unnecessary caller knowledge
- unsafe concurrency transfer
- incorrect combinations of related types
- type erasure at the wrong layer
- abstraction noise
- test seams that exist only because type relationships are weak

If you cannot name the concrete problem the compiler would help prevent, reject the candidate.

## Genericity Has a Budget

Static information is valuable only when the cost of carrying it remains local.

Every candidate must account for the genericity budget it consumes:

- generic parameter propagation across layers
- longer signatures and `where` clauses
- harder diagnostics
- code specialization/build-time cost
- source/ABI constraints
- reduced ability to store heterogeneous values
- extra type-erasure boundaries
- harder test fixtures
- increased cognitive load for humans and coding agents

A design that improves one local invariant but forces generic parameters through unrelated modules is usually a net loss.

Prefer designs where generic complexity is concentrated inside a deep module and callers see a small, stable interface.


## Genericity Has a Budget

Static information is valuable only when the cost of carrying it remains local.

Every candidate must account for the **genericity budget** it consumes:

- generic parameter propagation across layers
- longer signatures and `where` clauses
- harder diagnostics
- code specialization/build-time cost
- source/ABI constraints
- reduced ability to store heterogeneous values
- extra type-erasure boundaries
- harder test fixtures
- increased cognitive load for humans and coding agents

A design that improves one local invariant but forces generic parameters through unrelated modules is usually a net loss.

Prefer designs where generic complexity is concentrated inside a deep module and callers see a small, stable interface.

---

# Workflow

Follow these phases in order:

1. Establish repository and toolchain constraints.
2. Map modules, major types, and important call paths.
3. Search for type-system pressure points.
4. Generate 3–5 strong candidates.
5. Adversarially attack each candidate.
6. Present the candidates in a visual HTML decision report.
7. Open the report in the user's browser.
8. Auto-select Strong candidates + the top recommendation.
9. Load `swift-architecture-pipeline` and execute (spec → implement-spec → review → PRs → cleanup).

Do not implement a candidate during exploration (steps 1–7).

`--explore-only` restores ask-and-stop after step 7.

---

# Phase 1: Establish Constraints

Inspect:

- `Package.swift`
- `// swift-tools-version`
- `swiftLanguageModes`
- `.swift-version`
- Xcode project settings
- deployment targets
- CI
- repository docs
- architecture docs
- `AGENTS.md`
- project-local skills

Record:

- Swift version
- language mode
- supported platforms
- module/target graph
- public library vs application boundaries
- ABI/source compatibility constraints
- testing framework
- concurrency model where documented

Do not propose a feature unsupported by the repository's compiler/language mode.

On Swift 6.4, `~Sendable`, `some P?`/`any P?`, `Iterable`, `Ref`/`MutableRef`, and associated-type `~Copyable` suppression are in play. Route implementation through `swift-64-whats-new`. Do not recommend `FilePath` in the Swift module; SE-0529 is Accepted, not Implemented.

Do not silently require a tools-version or deployment-target migration.

## Public API and ABI Gate

Before recommending protocol/generic changes in public libraries or binary frameworks, inspect:

- whether the protocol/type is `public` or `open`
- `@frozen`
- `@inlinable`
- `@usableFromInline`
- library evolution settings
- whether external conformances exist
- whether adding associated types or protocol requirements is source-breaking
- whether changing opaque/existential return types changes source compatibility
- whether generic specialization leaks into public ABI

Do not recommend a type-system improvement as a "refactor" if it is actually an API migration.

Call out migration semantics explicitly.

For app-internal/package-internal code, do not manufacture ABI concerns.

---

# Phase 2: Build a Type-System Map

Do not grep mechanically and immediately propose refactors.

Build a mental map of where types matter.

Identify:

- central protocols
- protocol hierarchies
- type erasers
- generic containers
- registries
- factories
- state machines
- domain enums
- classes carrying mostly immutable data
- classes with identity/lifecycle
- generic functions
- concrete functions with repeated overload families
- APIs using `Any`
- APIs using `any Protocol`
- APIs returning `some Protocol`
- cross-module interfaces
- concurrency boundaries
- public/package APIs
- frequently changed types

For important types, understand:

- callers
- conformers
- associated inputs/outputs
- ownership
- mutation
- isolation
- storage requirements
- whether heterogeneity is real
- whether the type is open or closed
- whether the relationship is static or runtime-selected

---

# Phase 3: Search for Type-System Pressure

Use these lenses.

These are signals, not automatic findings.

---

## Lens A: Lost Type Relationships

Look for APIs where two or more types are related semantically but the compiler does not know it.

Examples:

```swift
protocol Tool {
    func execute(_ input: Any) async throws -> Any
}
```

Potential direction:

```swift
protocol Tool {
    associatedtype Input: Sendable
    associatedtype Output: Sendable

    func execute(_ input: Input) async throws -> Output
}
```

Look for:

- input/output pairs related by convention
- source/destination types that must share a value type
- request/response pairs
- parser/input/result relationships
- command/handler/result relationships
- repository/entity relationships
- decoder/model relationships
- event/payload relationships

Strong candidate test:

> Can a wrong combination compile today that should be rejected by the compiler?

If yes, generics or associated types may be justified.

---

## Associated Type vs Generic Parameter

Use an associated type when the type relationship belongs to the conforming type's identity/capability.

Use a generic parameter when the relationship belongs to one operation.

Example intuition:

```swift
protocol Parser {
    associatedtype Input
    associatedtype Output
}
```

when each parser has a stable input/output pair.

Prefer:

```swift
func transform<Input, Output>(...)
```

when the relationship varies per call rather than per conformer.

Do not force associated types into protocols when the operation-level generic is simpler.

---

## Lens B: Generic Constraints That Encode Domain Law

## Associated Type vs Generic Parameter

Use an associated type when the relationship belongs to the conforming type's identity or capability.

Use a generic parameter when the relationship belongs to one operation.

Example:

```swift
protocol Parser {
    associatedtype Input
    associatedtype Output
}
```

when each parser has a stable input/output pair.

Prefer an operation-level generic when that relationship varies per call.

Do not force associated types into protocols when a generic function is simpler.


Look for generic parameters that are unconstrained or loosely constrained even though the domain requires relationships between them.

Example:

```swift
protocol Store {
    associatedtype Value
}
```

Potential operation:

```swift
func transfer<S: Store, D: Store>(
    from source: S,
    to destination: D
) where S.Value == D.Value
```

Search for:

- runtime equality checks on type metadata
- repeated casts after generic calls
- documentation saying "these types must match"
- functions that accept independent type parameters that are actually linked
- protocol combinations repeatedly checked at runtime

Use:

- `where`
- same-type constraints
- associated-type constraints
- generic parameter constraints
- conditional conformances

only when they encode a real semantic relationship.

## Compile-Time Ergonomics

Advanced generic design can impose real compiler and developer costs.

Look for:

- deeply nested generic wrappers
- long same-type constraint chains
- recursive generic protocols
- overload sets that become ambiguous
- diagnostics that no longer point clearly to the offending call
- generic signatures leaking through many layers
- large generic bodies specialized repeatedly

Do not recommend a design that materially harms compile-time or diagnostic quality unless the correctness gain is substantial.

Prefer moving complex generic machinery behind a deep module so most of the codebase does not see it.


## Compile-Time Ergonomics

Advanced generic design can impose real compiler and developer costs.

Look for warning signs:

- deeply nested generic wrappers
- long same-type constraint chains
- recursive generic protocols
- overload sets that become ambiguous
- diagnostics that no longer point clearly to the offending call
- large generic bodies duplicated across specializations
- generic signatures leaking through many public/internal layers

Do not recommend a design that materially harms compile-time or diagnostics unless the correctness gain is substantial.

Prefer moving complex generic machinery behind a deep module so most of the codebase does not see it.

---

## Lens C: `some` vs `any`

Treat this as a first-class architectural question.

### Prefer `some` when:

- the implementation chooses one concrete conforming type
- callers do not need to switch concrete implementations at runtime
- the concrete type should remain hidden
- preserving static identity helps composition
- existential storage is unnecessary

Example:

```swift
func makeParser() -> some Parser
```

### Prefer `any` when:

- runtime heterogeneity is real
- values with different concrete types must share storage
- plugins/adapters are selected dynamically
- module boundaries intentionally erase concrete implementation
- existential semantics simplify the architecture more than generics would

Example:

```swift
let tools: [any Tool]
```

### Prefer constrained existentials when:

- heterogeneity is required
- but an associated type relationship still matters

Conceptually:

```swift
any Collection<Element>
```

when the supported Swift version allows the required primary-associated-type expression.

Review the type-information continuum:

```text
Concrete Type
    ↓
T: Protocol
    ↓
some Protocol
    ↓
constrained any Protocol<...>
    ↓
any Protocol
    ↓
Any
```

Moving downward generally loses compiler-visible information.

Do not automatically move upward.

The right point depends on runtime requirements.

Also verify semantics:

- `some` preserves one hidden concrete type per declaration; it is not arbitrary runtime variation
- `any` introduces existential semantics and can affect `Self`/associated-type usability
- constrained existentials are useful only when that constrained associated type matters to callers
- changing between `some` and `any` can alter storage, overload resolution, composition, and source compatibility

Never recommend `some`/`any` changes from syntax alone. Inspect call sites and storage needs.


Also verify semantics:

- opaque result types (`some`) preserve one hidden concrete type per declaration, not arbitrary runtime variation
- existentials (`any`) introduce existential semantics and may affect protocol requirements involving `Self`/associated types
- constrained existentials are only useful when the constrained associated type is actually part of the caller's contract
- switching between `some` and `any` can change overload resolution, storage, composition, and source compatibility

Never recommend `some`/`any` changes from syntax alone. Inspect call sites and storage needs.

---

## Lens D: Misplaced Type Erasure

Search for:

- `AnyFoo`
- `AnyRepository`
- `AnyStore`
- `AnyTool`
- `AnyHandler`
- closures used as ad-hoc erased protocol implementations
- `Any`
- `AnyObject`

Ask:

- Is erasure required for heterogeneous storage?
- Is it required at a module boundary?
- Does it hide a relationship callers still need?
- Is it being introduced too early?
- Could the erased boundary move outward?

A strong refactor often preserves concrete/generic types internally and erases only at the true dynamic boundary.

The skill should identify the **erasure boundary**, not merely whether erasure exists.

Good:

```text
generic domain core
→ package/internal adapter
→ erased plugin registry
```

Suspicious:

```text
public API
→ immediate erasure
→ repeated casts internally
```

Do not remove useful erasure just to make types more generic.

Identify the **erasure boundary**, not merely whether erasure exists.

Good:

```text
generic domain core
→ package/internal adapter
→ erased plugin registry
```

Suspicious:

```text
public API
→ immediate erasure
→ repeated casts internally
```

Strong designs usually preserve type information internally and erase only at the true dynamic boundary.


---

## Lens E: Protocol Quality

Protocols should define meaningful capabilities or substitution boundaries.

Look for:

- giant protocols
- protocols with unrelated requirements
- protocols that simply mirror one concrete type
- protocols created only for tests
- protocol inheritance pyramids
- optional/default requirements hiding weak cohesion
- protocols with associated relationships flattened into `Any`

Potential directions:

- split by capability
- merge shallow protocol layers
- replace open protocol families with enums when the set is truly closed
- add associated types when conformers have meaningful dependent types
- remove protocols where a concrete deep module is clearer

Do not equate "protocol-oriented" with "more protocols."

Elite protocol design means **few strong protocols**.

Before recommending a protocol or preserving one, look for evidence of an open world:

- multiple real conformers
- plugin/extensibility requirements
- platform substitution at a genuine seam
- package/client extension points
- heterogeneous runtime storage

If the family is closed and controlled by one module, an enum or concrete deep module may be clearer.

When adding associated types to an existing protocol, inspect whether current callers rely on existential use. Do not make common storage/use sites dramatically harder without a compensating architectural gain.


Before recommending a protocol or preserving one, look for evidence of an open world:

- multiple real conformers
- plugin/extensibility requirements
- test or platform substitution at a genuine boundary
- package/client extension points
- heterogeneous storage/dynamic dispatch needs

If the family is closed and controlled by one module, an enum or concrete deep module may be clearer.

---

## Lens F: Open vs Closed Worlds

Ask whether a family of behaviors/types is genuinely extensible.

If the set is closed and known:

```swift
protocol State {}
struct Idle: State {}
struct Running: State {}
struct Failed: State {}
```

may be worse than:

```swift
enum State {
    case idle
    case running
    case failed(Error)
}
```

Prefer enums for closed state spaces.

Prefer protocols for open capability sets.

But verify that "closed" is actually stable.

A public enum used as an external extension point may be the wrong closure mechanism, while an internal protocol with controlled conformers may still be appropriate.

This is one of the highest-value architecture distinctions in Swift.

Verify that "closed" is actually stable.

A public enum used as an external extension point may be the wrong closure mechanism, while an internal protocol with controlled conformers can still be appropriate.


---

## Lens G: Enums and Associated Values

Look for:

- multiple booleans encoding modes
- optional soup
- parallel optional payloads
- error + result stored simultaneously
- string states
- dictionaries keyed by magic values
- switch logic spread across unrelated fields

Potential direction:

```swift
enum ExecutionState {
    case idle
    case running(Request)
    case completed(Output)
    case failed(ExecutionError)
}
```

The compiler should force handling of meaningful state transitions.

Avoid `default` in closed enum switches when explicit exhaustiveness provides future refactor safety.

---

## Lens H: Value Semantics

Look for classes that:

- have no meaningful identity
- mostly store immutable data
- are passed as snapshots
- exist only as DTOs/configuration/results
- require synchronization only because they are shared references

Potential directions:

- `struct`
- immutable properties
- copy-on-write where justified

Do not mechanically convert classes to structs.

Reference semantics may be correct for:

- identity
- graph nodes
- lifecycle
- observation
- Objective-C/XPC interop
- shared caches
- framework requirements

A value-type recommendation must explain what correctness or locality improves.

Also inspect semantic and performance cost:

- large values may need copy-on-write or reference-backed storage
- graph nodes and identity-sensitive objects may not map cleanly to structs
- observation frameworks may require reference identity
- copying a lock/resource wrapper may be semantically wrong

Do not equate value semantics with "struct everywhere."


Also inspect cost/semantics:

- large values may need copy-on-write or reference-backed storage
- identity-sensitive collections/graphs may not map cleanly to structs
- observation frameworks may require reference identity
- copying a lock/resource wrapper may be semantically wrong

Do not equate value semantics with "struct everywhere."

---

## Lens I: Semantic/Newtype Wrappers

Look for raw primitive values that are easy to mix accidentally.

Examples:

```swift
String // Rule ID
String // Pack ID
String // User ID
```

Potential direction:

```swift
struct RuleID: Hashable, Sendable {
    let rawValue: String
}
```

Use wrappers when they:

- prevent accidental mixing
- enforce validation
- carry domain meaning
- improve APIs

Do not create wrappers around primitives with no semantic gain.

---

## Lens J: Phantom-State Generics

Advanced tool. Use sparingly.

Look for lifecycle/state transitions where using the wrong phase is dangerous and frequently checked at runtime.

Example:

```swift
enum Unvalidated {}
enum Validated {}

struct Request<State> {
    ...
}

func validate(
    _ request: Request<Unvalidated>
) throws -> Request<Validated>
```

Good candidates:

- authentication state
- validation state
- transaction lifecycle
- resource initialization
- permission/authorization state
- compile/build pipeline stages

Reject if:

- there are only one or two call sites
- the state machine is simple enough for an enum
- generic state leaks everywhere
- the type burden exceeds the safety gain

Phantom-state designs are Tier 3 tools.

Before recommending one, explicitly compare it to:

- a plain enum state machine
- a validating initializer or factory
- a deeper module that hides the transition entirely

If callers do not need to observe the state parameter, hiding the transition behind a module is often superior.


Before recommending one, explicitly compare it to:

- a plain enum state machine
- a validating initializer/factory
- a deeper module that hides the transition entirely

If callers do not need to observe the state parameter, hiding the transition behind a module is often superior.

---

## Lens K: Conditional Conformance

Look for generic wrappers/containers that manually reimplement behavior based on their element type.

Potentially useful:

```swift
extension Box: Equatable where Value: Equatable {}
extension Box: Sendable where Value: Sendable {}
```

Look for:

- repeated forwarding equality/hash/codable/sendable implementations
- wrapper types whose capabilities should derive from contained type capabilities

Use conditional conformance to preserve composition.

Be cautious with retroactive conformances across module boundaries.

A convenient conformance can create future conflicts if neither the type nor protocol is owned by the module.


Be cautious with retroactive conformances across module boundaries.

A convenient conformance can create future conflicts if neither the type nor protocol is owned by the current module.

Prefer conformances where at least one side of the relationship is architecturally owned by the module, or document the compatibility risk.

---

## Lens L: Typed Errors

Look for domains where callers need to reason about a closed failure set.

Potential direction:

```swift
func compile(
    _ graph: Graph
) throws(CompilationError) -> Program
```

Use typed throws when:

- failure domain is intentionally closed
- exhaustive caller handling is valuable
- the type is stable enough

Do not force typed throws onto infrastructure APIs wrapping open-ended external errors.

Typed throws can also become noisy if exact error types propagate through generic layers that callers do not care about.

Prefer typed throws where exhaustive failure knowledge is part of the contract.


Also inspect protocol/generic propagation.

Typed throws can improve a closed domain but become noisy if every generic layer must carry an exact error type that callers do not care about.

Prefer typed throws where exhaustive failure knowledge is part of the contract.

---

## Lens M: Generics Across Concurrency Boundaries

Look for generic values crossing tasks/actors where sendability is implicit.

Potential directions:

```swift
protocol Tool {
    associatedtype Input: Sendable
    associatedtype Output: Sendable
}
```

or generic constraints such as:

```swift
func execute<T: Sendable>(_ value: T) async -> T
```

Do not add `Sendable` mechanically.

Add it where the architecture actually transfers values across concurrency domains.

Inspect closure captures and associated types, not only the top-level generic parameter.

A generic API can constrain `T: Sendable` while still capturing non-Sendable state unsafely.


Inspect closure captures and associated types, not just the top-level generic parameter.

A generic API can be `T: Sendable` while still capturing non-Sendable state unsafely.

---

## Lens N: Primary Associated Types and Constrained Existentials

Where supported by the toolchain, inspect protocols whose key associated type is part of the protocol's semantic identity.

These may support APIs that are more expressive than unconstrained existentials while avoiding full generic propagation.

Look for:

- collections of protocol values where one associated type must be fixed
- APIs accepting heterogenous conformers that share one associated type
- type erasers whose only purpose is to pin one associated type

Use constrained existentials when they simplify callers and preserve the relationship that matters.

Do not force primary-associated-type syntax into protocols that do not benefit from existential use.

---

## Lens O: Ownership Features

Advanced and narrow.

Look for genuinely unique resources:

- file descriptors
- native handles
- locks
- transaction handles
- sockets
- buffers with exclusive ownership
- resources that must be consumed exactly once

Potential tools:

- `borrowing`
- `consuming`
- `~Copyable`

Reject ordinary model/value candidates.

Ownership syntax should encode a real lifecycle invariant.

---

## Lens P: Variadic Generics / Parameter Packs

Tier 3 only.

Consider only when the codebase has repeated generic overload families or tuple-like APIs where parameter packs materially reduce duplication while preserving type information.

Do not introduce parameter packs because they are advanced Swift.

The benefit must be obvious and recurring.

Also verify:

- supported Swift version
- compiler maturity for the specific pattern
- whether diagnostics remain understandable
- whether a simpler overload family is actually easier to maintain

---

# Architecture Before Generics

For every candidate, ask:

> Is this fundamentally a type-relationship problem, or a module-boundary problem?

If callers know too much because coordination leaks outward, deepen the module first.

Do not solve module-depth problems with:

```swift
GenericManager<A, B, C, D>
```

when the real fix is a smaller interface.

Generics should encode relationships **inside or across good boundaries**, not compensate for bad boundaries.

---

# Anti-Patterns: Reject These Recommendations

Do not recommend:

- generics used once with no meaningful constraint
- protocol + associated type for a closed three-case state machine
- generic wrappers that merely rename a concrete implementation
- `some` replacing `any` when runtime heterogeneity is required
- `any` replacing generics merely to simplify compiler errors
- type erasure solely to make a generic API storable
- phantom types for trivial state
- complex recursive generic structures with no clear invariant gain
- new protocols solely for mocking
- generic performance specialization without evidence
- class→struct churn with no semantic benefit
- `Sendable` annotations added only to silence diagnostics
- ownership features in ordinary app models
- parameter packs for code that is already clear

"More advanced Swift" is not a success criterion.

---

# Candidate Tiers

Classify opportunities.

## Tier 1 — Clear Compiler Wins

Examples:

- replace `Any`
- replace force casts
- enum state modeling
- associated values
- meaningful newtypes
- `some` instead of unnecessary existential returns
- generic same-type constraints
- natural `Sendable` constraints
- narrow capability protocols

These should usually have obvious local correctness benefits.

## Tier 2 — Architectural Type-System Wins

Examples:

- associated-type protocol redesign
- primary associated types
- constrained existentials
- moving type erasure outward
- type-safe registries
- conditional conformances
- generic adapters
- value-semantic subsystem boundaries
- typed error architecture

These may affect a subsystem or module.

## Tier 3 — Advanced / High Scrutiny

Examples:

- phantom-state generics
- `~Copyable`
- `borrowing` / `consuming`
- parameter packs
- sophisticated type erasure
- recursive generic designs

Include a Tier 3 candidate only with strong repository evidence.

---

# Candidate Requirements

Generate at most 5 candidates.

Prefer 3 excellent candidates.

Each candidate must answer:

1. What weak type relationship exists today?
2. What runtime behavior/cast/state check exists because of it?
3. Which Swift feature would encode the relationship?
4. What becomes impossible to express incorrectly?
5. What becomes easier for callers?
6. What becomes harder for callers?
7. Does generic complexity leak across module boundaries?
8. Could an enum or deeper module solve this more simply?
9. Is runtime heterogeneity real?
10. What migration risk exists?
11. Where does generic complexity stop?
12. What is the intended erasure boundary?
13. Does the proposal worsen compiler diagnostics or build-time complexity?
14. Is any public/source/ABI migration required?
15. What simpler design was considered and rejected?

If the candidate cannot answer these clearly, discard it.

---

# Candidate Scoring

Score 1–5:

- **Compiler gain** — how much correctness moves to compile time
- **Type information** — how much useful type identity/relationship is preserved
- **Architecture leverage** — how many callers/changes benefit
- **API clarity** — whether call sites become easier to understand
- **Locality** — whether less code/context must be understood
- **Testability** — whether fewer runtime permutations/mocks are needed
- **Complexity cost** — how much generic/protocol complexity is introduced
- **Migration risk** — regression/churn risk
- **Genericity spread** — how far type parameters/constraints propagate
- **Diagnostic quality** — whether compiler errors remain understandable
- **Boundary quality** — whether erasure/dynamic dispatch sits at the right layer

Do not mechanically add the scores.

A candidate with 5/5 compiler gain but 5/5 complexity cost may be a bad design.

---

# Adversarial Review

Before surfacing a candidate, attack it.

Ask:

- Is this real type safety or generic cleverness?
- Does the compiler gain justify the syntax burden?
- Could a plain enum solve this?
- Could a deeper module solve this?
- Does the design force generic parameters through unrelated layers?
- Is `any` actually correct here?
- Does `some` preserve enough flexibility?
- Would type erasure at one outer boundary be simpler?
- Is the protocol truly open for extension?
- Does value semantics break identity/lifecycle assumptions?
- Does this create source/ABI compatibility issues?
- Does the supported Swift version allow the design?
- Is this likely to make coding agents struggle with compiler diagnostics?
- Would a senior Swift engineer understand the API without decoding type gymnastics?
- Does the proposal force generic parameters through modules that do not care about them?
- Is the new protocol still usable at the actual call sites that matter?
- Am I creating an ABI/source migration and calling it a refactor?
- Does the compiler produce better errors after this change, or worse ones?
- Can I move the generic complexity behind a deeper module?
- Is the type-erasure boundary intentionally chosen?
- Is the recommendation robust if another conformer or case is added later?
- Does the proposal force generic parameters through modules that do not care about them?
- Is the new protocol still usable at the actual call sites that matter?
- Am I creating an ABI/source migration and calling it a refactor?
- Does the compiler produce better errors after this change, or worse ones?
- Can I move the generic complexity behind a deeper module?
- Is the type erasure boundary intentionally chosen?
- Is the recommendation robust if another conformer/case is added later?

Reject candidates that fail this review.

---

# HTML Decision Report

Render the result as a local HTML report.

Name it:

```text
swift-type-system-review-<repo>-<timestamp>.html
```

Write it outside the repository, preferably:

```bash
${TMPDIR:-/tmp}
```

Use the visual guidance in `HTML-REPORT.md`.

Open it in the user's default browser.

macOS:

```bash
open "<absolute-path>"
```

Linux:

```bash
xdg-open "<absolute-path>"
```

Windows:

```powershell
start "" "<absolute-path>"
```

If browser opening is unavailable, print the path.

---

# Required Report Structure

## Header

Show:

- repository
- branch
- Swift version/language mode
- modules explored
- candidate count

## Type-System Map

Show a compact diagram of the important relationships discovered.

Examples:

```text
ToolRegistry
    │
    ├── [any Tool]
    │       ├── ShellTool
    │       ├── FileTool
    │       └── SearchTool
    │
    └── execute(input: Any) -> Any
```

or:

```text
Parser<Input, Output>
Command<Payload>
Store<Value>
```

Use actual repository names.

## Type-Information Gradient

Include a small visual:

```text
MORE STATIC INFORMATION

Concrete
   ↓
T: P
   ↓
some P
   ↓
any P<Constraint>
   ↓
any P
   ↓
Any

MORE RUNTIME FLEXIBILITY
```

Use it only as explanatory context, not as a rule that "higher is better."

## Candidate Cards

Each card must include:

- title
- tier
- recommendation strength
- repository evidence
- current type relationship
- proposed type relationship
- relevant Swift mechanisms
- compiler gain
- API/caller gain
- complexity introduced
- migration risk
- likely scope
- "why not a simpler design?" section

## Before / After Type Diagram

Example:

```text
BEFORE

Tool
├── execute(Any) → Any
└── callers cast result

AFTER

Tool
├── associatedtype Input
├── associatedtype Output
└── execute(Input) → Output

Compiler proves:
Input ↔ Tool ↔ Output
```

## Compiler Gain

Make this prominent.

Examples:

```text
Wrong parser/result pair
Before: runtime cast failure
After: does not compile
```

```text
Unhandled state
Before: optional/boolean combination
After: exhaustive switch diagnostic
```

## Complexity Cost

Every candidate must show what gets more complicated.

Examples:

- generic parameters propagate to two callers
- existential storage now requires an outer erasure boundary
- public protocol changes are source-breaking
- additional where-clauses increase signature complexity

Do not hide costs.

## Top Recommendation

Recommend one candidate. Do not implement it during exploration.

Explain why its compiler/architecture gain justifies its complexity.

---

# After Candidates Are Ready

Unless `--explore-only`, load `the `swift-architecture-pipeline` skill (if installed; otherwise stop after reporting candidates)` and continue from auto-select through spec, implement-spec, review, PRs, and cleanup.

Before each ticket's implementation, re-explore that candidate deeply:

1. inspect all callers
2. inspect conformers
3. inspect public/package API
4. inspect tests
5. inspect serialization/persistence
6. inspect concurrency/sendability
7. inspect compatibility requirements
8. challenge the proposed generic design again

Then produce a concrete refactor design (in the spec/ticket, implemented by implement-spec subagents).

Do not defend the original recommendation if deeper evidence disproves it.

---

# Success Criteria

A successful type-system refactor should produce one or more of these outcomes:

- invalid combinations stop compiling
- casts disappear
- `Any` disappears from domain code
- caller-visible state space shrinks
- protocols become smaller and more meaningful
- associated input/output relationships become explicit
- existential erasure moves to a deliberate dynamic boundary
- `some` hides implementation without losing type identity
- `any` is used only where runtime heterogeneity is intentional
- closed state becomes exhaustive
- value semantics make ownership clearer
- concurrency boundaries become `Sendable`-checked
- tests need fewer invalid runtime combinations
- a deep module can expose a smaller typed interface
- future coding agents get stronger compiler diagnostics during refactors
- generic complexity remains local rather than infecting unrelated layers
- dynamic erasure is concentrated at intentional boundaries

Do not measure success by generic line count.

Do not measure success by protocol count.

Do not measure success by sophistication.

Measure success by **how much architecture the compiler can now prove**.

---

# Final Principle

Elite Swift generics are not about writing the most generic code.

They are about expressing relationships precisely enough that the compiler can reject entire categories of incorrect programs while keeping the API understandable.

Prefer the simplest type-system design that makes an important invariant impossible to violate.

When two designs provide similar safety, prefer the one with:

- smaller caller-facing types
- less generic propagation
- clearer diagnostics
- fewer compatibility constraints
- a deeper module boundary
