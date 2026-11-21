---
name: swift-systems-safety
description: Use when Swift touches POSIX, file descriptors, sockets, pointers, buffers, C ABI, mmap, unsafe code, or manual cleanup. Do not invoke for ordinary safe collection code.
---

# Swift systems safety

Make every unsafe boundary small, typed, bounded, and lifetime-proven. Unsafe APIs are escape hatches from static guarantees, not implementation style.

## Procedure

1. State the external contract: ownership, validity, alignment, initialization, length, errno behavior, blocking/cancellation, and cleanup.
2. Wrap raw handles in a narrow type. Use `~Copyable` when duplicate close/use-after-close is invalid; keep borrowed operations non-consuming.
3. Bound all lengths and arithmetic before allocation, pointer formation, or indexing. Reject malformed input before touching memory.
4. Bind and access memory only for the documented lifetime and alignment. Do not assume a byte buffer is bound to an arbitrary typed value; do not escape pointers from their closure/lifetime.
5. Translate C/POSIX results immediately into typed Swift outcomes. Preserve errno at the call site, retry only interruptible operations where the contract allows, and distinguish EOF, would-block, timeout, and failure.
6. Test empty, maximum, truncated, misaligned, interrupted, closed, and allocation-failure paths. Run sanitizers or platform diagnostics when available.

Read [references/systems-boundary-guide.md](references/systems-boundary-guide.md) before changing pointer or descriptor code.

## Swift 6.4

Prefer `Span`/`OutputSpan`, `withTemporaryAllocation`, and safe `RawSpan` loads over raw pointer+count. C/C++ export and `std::span` bridging go through `swift-64-interop-c`. POSIX/fd/mmap rules in this skill still apply.

## Guardrails

- Never use `@unchecked Sendable` to paper over a raw pointer or handle whose synchronization/lifetime is unknown.
- Never assume `defer` makes an aliased descriptor safe; prove single ownership.
- Never use `memcpy`/rebinding as a substitute for a typed lifetime argument.
- Keep system calls and unsafe blocks close to their checked wrapper; do not spread raw integers through the domain.

## Completion contract

Report the safety invariant, bounds and lifetime proof, cleanup ownership, error mapping, and the strongest platform-specific verification performed.
