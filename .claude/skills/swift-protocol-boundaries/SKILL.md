---
name: swift-protocol-boundaries
description: Use when Swift defines or changes XPC, socket, IPC, Codable, serialization, plugin, or other process/module boundaries. Do not invoke for private in-process helper APIs with no compatibility or trust boundary.
---

# Swift protocol boundaries

Treat the boundary as a hostile, versioned contract. Keep transport mechanics, schema, policy, and domain decisions separate.

## Procedure

1. Define actors, trust assumptions, direction, framing, maximum sizes, deadlines, cancellation, and compatibility window.
2. Model messages as typed enums/structs with explicit success, rejection, and indeterminate outcomes. Reject unknown or malformed data before policy execution.
3. Separate wire schema from domain types when evolution, secrecy, or validation differs. Make optionality, defaults, numeric bounds, and canonical encoding explicit.
4. Implement bounded framing and one ownership path for buffers/handles. Handle partial reads/writes, EOF, timeout, cancellation, and peer death distinctly.
5. Version deliberately: additive fields only when older readers tolerate them; negotiate or reject incompatible versions; never silently reinterpret bytes.
6. Test malformed, oversized, truncated, reordered, duplicated, replayed, unknown-version, and unauthorized messages, plus clean shutdown.

Read [references/wire-contract-guide.md](references/wire-contract-guide.md) for the contract checklist.

On Swift 6.4, C/C++/Java wire types go through `swift-64-interop-c`. Prefer `Span` over pointer+count at those boundaries. Process spawning uses Subprocess 1.0 (`swift-64-toolchain`), not ad-hoc `Process`.

## Guardrails

- Do not use `[String: Any]` as a wire schema.
- Do not expose implementation types, file paths, raw errors, or private policy state across the boundary unless they are part of the contract.
- Fail closed for authorization, framing, version, and size failures. Document any deliberate fail-open behavior.
- A successful decode is not authorization and a successful transport write is not successful execution.
- A retired wire method is an unknown key: `decodeFailed`, not `unknownMethod`. `unknownMethod` is for a still-decoded case the server refuses.
- Exclusive-write lists are a collision fence, not the compile set. A renamed or retyped public field needs every comparing test and first-call site, or keep a shim.
- Handshake and method calls need distinct connect budgets on on-demand listeners. An unused timeout field is not a timeout. If timeout is labeled "down", idle spawn looks like a crash.
- Collapsing later tokens is not redaction if the first token is itself a path or `KEY=value`.
- Fake HOME does not fake Mach services. A Darwin hook process proof that skips LaunchAgent park is evaluating whoever owns the login XPC. Park login rvd and keep toolchain HOME off the fixture HOME.
- A plugin-owned Ask wait is not a pause unless it outlives the host hook budget. Host Allow that runs the tool is leftover-ask-as-permit even if a pause API exists.
- Shared launchd proofs are a machine mutex. Retry after contention before treating the ticket as failed.

## Completion contract

Report schema/version, size and timeout bounds, error mapping, trust decisions, compatibility story, and malformed-input proof.
