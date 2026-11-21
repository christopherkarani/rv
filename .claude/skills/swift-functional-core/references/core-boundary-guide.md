# Core-boundary guide

Use this shape when it matches the domain:

```swift
struct DecisionInput: Sendable { /* facts */ }
enum Decision: Equatable { case allow, deny(reason: Denial), indeterminate(ErrorCode) }
func decide(_ input: DecisionInput) -> Decision { /* no I/O */ }
```

The shell loads facts, calls `decide`, then interprets the result through an injected capability. A reducer can model `(State, Event) -> (State, [Effect])`; an effect runner remains outside the reducer.

Before extraction, list the values the code reads and mutates. If the proposed “core” still reaches a clock, environment, logger, task, or singleton, the boundary is not pure yet. If the pure function becomes a parameter-passing maze, stop and preserve the existing cohesive abstraction.
