# Value-semantics guide

| Question | Value semantics | Identity semantics |
| --- | --- | --- |
| Can two instances be substituted when equal? | Usually yes | Usually no |
| Does mutation belong to one caller? | Copy before mutation or use COW | Shared mutation is visible |
| Is lifetime unique? | Use `~Copyable` if duplication is invalid | Class/actor may share references |
| Is thread safety automatic? | Only for immutable/sendable state | No; references still need isolation |

For a suspected COW regression, measure: baseline construction, read-only pass, first mutation, repeated mutation after aliasing, and peak memory. Include optimized and debug configurations where relevant.
