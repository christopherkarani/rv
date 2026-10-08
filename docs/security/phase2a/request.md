Continue RV Agent Identity Phase 2, but **do not attempt to finish all of Phase 2 in this pass**.

The previous Phase 2 attempt correctly ended:

```text
PHASE 2 BLOCKED
```

Do not start Phase 3.

Do not merge the existing Phase 2 draft as a complete feature.

The immediate objective is to solve the largest architectural blocker:

> **Establish a real authenticated trust relationship between `rvd` and the workspace host so `rvd` can obtain and continuously validate Agent Principal authority without trusting caller-supplied IDs.**

Repository baseline:

```text
phase-1Identity
a85151b6 — Harden AgentInstanceRegistry concurrent teardown
```

There is an existing uncommitted `phase-2Identity` draft containing useful peer-authentication and refusal-boundary work.

Treat that draft as research/reference material, not as approved architecture.

---

# Goal

At the end of this task, `rvd` must be able to answer:

```text
"This request refers to AgentInstance X.

Which workspace host owns X?

Am I talking to that authentic workspace host?

Does that host currently consider X active?

Does X still belong to RuntimeSession Y / Workspace Z?

Is the host generation still current?"
```

without trusting an arbitrary client that merely supplies those IDs.

This task does **not** yet implement:

- human approval resolution
- LocalAuthentication integration
- HookHost removal
- credential/tag migration
- measured launch
- Secrets
- Phase 3
- full C client support
- all remaining local-bypass closure

---

# 1. Preserve the failed Phase 2 attempt

Before making new changes:

1. Record current branch, HEAD and working tree.
2. Save the existing Phase 2 draft in a recoverable form.
3. Do not merge it into Phase 1.
4. Do not lose its platform-proof artifacts or tests.
5. Identify which pieces are reusable without dragging incomplete behavior with them.

Return an inventory:

```text
SAFE TO REUSE
NEEDS REDESIGN
DEFER
```

Do not assume the previous implementation is correct merely because its focused tests passed.

---

# 2. Ground-truth current topology

Trace the real runtime topology from source.

Document exactly which process owns:

```text
AgentInstanceRegistry
WorkspaceSessionSupervisor
RuntimeCapability
RuntimeChannelBinding
rvd ServiceRuntime
workspace control socket
XPC listener
```

Trace actual process boundaries.

Answer:

- Is there one workspace host per workspace?
- Who launches it?
- How does `rvd` discover it?
- Which process creates the control socket?
- What survives host restart?
- Which existing owner token / generation / PID / socket inode facts exist?
- Which channel can support authoritative principal-validity RPCs?

Do not design until this is established from code.

---

# 3. Define AgentPrincipalReference

Implement or finalize the cross-process reference described by the Agent Identity spec.

Conceptually:

```text
AgentPrincipalReference {
    AgentInstanceID
    RuntimeSessionID
    WorkspaceSessionID
    WorkspaceHostID
    WorkspaceHostGeneration
}
```

Exact Swift names may follow repository conventions.

Properties:

- Codable/wire representation is allowed because this is a **reference**, not authority.
- Possessing or fabricating this value grants nothing.
- Every use must be verified against an authenticated workspace-host channel.
- Host generation is mandatory.
- Runtime/workspace/instance mismatch fails closed.
- Historical/stale references never reactivate authority.

---

# 4. Authenticate the workspace host to rvd

Build the real authenticated registration/connection path.

`rvd` must not accept:

```text
"I am workspace host abc"
```

because a process knows:

- workspace ID
- socket path
- PID
- owner token
- same UID

Use the peer-authentication primitives already proven in the Phase 2 draft where appropriate.

The host must establish both:

```text
authenticated RV component role = workspace host
```

and:

```text
specific live WorkspaceHost identity/generation
```

The workspace owner token may remain a correlation secret.

It is not sufficient authentication by itself.

---

# 5. Host generation

Introduce an explicit unpredictable or monotonic-per-host-start generation identity.

Required property:

> A principal reference issued by workspace-host incarnation A must become invalid after that host dies and incarnation B starts.

Do not infer this only from PID.

Do not let disk history recreate the generation as active authority.

On host restart:

```text
old AgentPrincipalReference → stale
```

even if:

```text
WorkspaceSessionID
socket path
workspace directory
```

remain similar.

---

# 6. Registration semantics

Define a trusted registration flow such as:

```text
workspace host starts
    ↓
establish authenticated channel to rvd
    ↓
rvd authenticates workspace-host component
    ↓
host proves workspace ownership/correlation
    ↓
host generation registered
    ↓
rvd stores live host connection
```

Important:

- registration lives only while the authenticated connection is alive.
- duplicate live host registration must have deterministic semantics.
- stale host cannot replace a current host merely by replaying identifiers.
- host connection loss immediately invalidates service-side authority derived from it.
- registry state is ephemeral.

Do not persist a registration and restore it as trusted after daemon restart.

---

# 7. Principal validity RPC

Implement the authoritative workspace-host RPC equivalent to:

```text
resolvePrincipal(reference)
validity(reference)
authorizePrincipal(reference, operation)
```

Use the smallest API that fits RV architecture.

The workspace host must validate using its Phase 1 `AgentInstanceRegistry`.

At minimum verify:

```text
instance exists
instance active
instance.runtimeSessionID matches
instance.workspaceSessionID matches
host generation matches
workspace host owns the registry
```

Return only trusted descriptive/validity data.

Never send:

```text
RuntimeCapability
raw admission capability
Secrets
```

to `rvd`.

---

# 8. Service-side live principal binding

`rvd` may cache descriptive information for audit/display.

It must NOT treat cached data as live authorization.

For an authority-bearing operation, require live validation according to clearly documented semantics.

At minimum invalidate on:

```text
workspace-host disconnect
host generation change
Agent Instance inactive
runtime mismatch
workspace mismatch
unknown instance
RPC failure
```

RPC failure must fail closed.

---

# 9. AuthenticatedAgentContext creation

Only trusted service code may create a service-side `AuthenticatedAgentContext`.

Allowed construction path:

```text
authenticated caller/channel
    +
AgentPrincipalReference
    +
authenticated workspace-host validation
    ↓
AuthenticatedAgentContext
```

Forbidden:

```text
client payload → AuthenticatedAgentContext
AgentInstanceID alone → AuthenticatedAgentContext
SessionID → AuthenticatedAgentContext
HookHost → AuthenticatedAgentContext
PID → AuthenticatedAgentContext
```

Keep untrusted wire structures distinct from trusted context types.

---

# 10. Agent action dispatch

Wire exactly one real agent-authority path through this mechanism.

Choose the canonical agent evaluation path.

End-to-end:

```text
agent/runtime authenticated channel
→ bound AgentPrincipalReference
→ rvd receives request
→ rvd verifies host binding/live principal
→ trusted context constructed
→ evaluation executes
```

Do not enable broad owner mutations yet.

The purpose is to prove one legitimate authenticated operation works rather than merely proving denial paths.

Required outcome:

> valid agent succeeds; forged/stale agent fails.

---

# 11. Revocation proof

End-to-end test:

1. launch/construct legitimate Agent Instance.
2. establish service-side reference.
3. successfully perform authorized operation.
4. revoke/terminate Agent Instance.
5. repeat same operation with same reference.

Expected:

```text
FAIL CLOSED
```

Also test:

```text
host dies
same reference reused
→ FAIL CLOSED
```

and:

```text
new host generation starts
old reference
→ FAIL CLOSED
```

---

# 12. Same-user impersonation proof

Use a real separate process.

Attempt to impersonate the workspace host using:

```text
same UID
known workspace ID
known socket path
copied owner token where feasible
forged host generation
forged AgentPrincipalReference
```

It must fail because it lacks the authenticated workspace-host component identity/channel.

Do not count an in-process mock as sufficient proof.

---

# 13. Socket forwarding / descriptor forwarding

Investigate whether an authenticated workspace-host channel can be forwarded or inherited by an untrusted contained process.

Prove one of:

```text
channel cannot be forwarded due to containment/descriptor rules
```

or:

```text
protocol cryptographically / connection-context binds each operation so forwarding cannot create authority
```

Do not leave this at "clients should not forward".

If current architecture cannot prevent meaningful forwarding, report this as BLOCKED.

---

# 14. Cross-process product proof

Previous Phase 2 evidence lacked a successful cross-process installed-role journey.

This task must include at least one genuine multi-process test:

```text
rvd process
workspace-host process
authorized client/runtime process
```

using the real transport stack.

No same-process XPC-only proof.

No fake peer structs.

Capture enough diagnostic evidence to prove which OS process identities were authenticated.

---

# 15. Development trust provisioning

The previous attempt had a protected trust manifest design but no working provisioning flow.

For this task, provide a real development/test installation mechanism that can provision the required component identity safely enough for product integration tests.

Requirements:

- explicit action
- not derived from basename/path alone
- protected from contained-agent writes
- deterministic cleanup
- cannot accidentally become a production wildcard

Do not solve general production installation UX yet if unnecessary.

But the tests must exercise a real successful trusted-role configuration.

---

# 16. Failure semantics

Required:

```text
unknown host                 → FAIL CLOSED
host disconnected            → FAIL CLOSED
wrong component role         → FAIL CLOSED
host generation mismatch     → FAIL CLOSED
unknown Agent Instance       → FAIL CLOSED
inactive Agent Instance      → FAIL CLOSED
runtime mismatch             → FAIL CLOSED
workspace mismatch           → FAIL CLOSED
validity RPC error           → FAIL CLOSED
forged reference             → FAIL CLOSED
same UID only                → no authority
owner token only             → no authority
```

Diagnostic-only operations remain separate.

---

# 17. Do not implement yet

Explicitly defer:

```text
human resolver integration
LocalAuthentication production flow
approval transaction completion
rule-save owner authorization
C-client successful authenticated mutation
EgressProxy identity
HookHost rewrite
tag credential rewrite
terminal reattachment rewrite
measured launch
Secrets
```

Do not widen scope because they are also Phase 2 blockers.

This task establishes the foundation those pieces require.

---

# 18. Tests

Add targeted tests for:

```text
host registration
host authentication
duplicate registration
generation replacement
disconnect invalidation
valid principal lookup
stale reference
wrong instance
wrong runtime
wrong workspace
inactive principal
RPC failure
same-user fake host
forged reference
cross-process legitimate success
cross-process impersonation failure
revocation after successful operation
host restart after successful operation
```

Concurrency:

Race:

```text
validity request ↔ host disconnect
validity request ↔ instance revoke
old host ↔ new host registration
```

No authority may survive the losing race.

---

# 19. Regression gates

Phase 1 must remain frozen.

Run:

```sh
Scripts/preflight.sh
Scripts/swift-6.4 test --filter RVDomainTests
Scripts/swift-6.4 test --filter RVPolicyTests
Scripts/swift-6.4 test --filter RVIsolationTests
Scripts/swift-6.4 test --filter RVIPCTests
Scripts/swift-6.4 test --filter RVServiceTests
```

Also run any narrower new cross-process product suite.

Broad failures caused by this work are blockers.

Do not accept "focused tests green" while relevant full modules fail.

---

# 20. Fresh adversarial review

Give a fresh reviewer only:

- spec
- diff
- topology
- tests

Ask them to break:

```text
workspace-host authentication
host generation
principal-reference freshness
disconnect invalidation
same-UID isolation
cross-process trust
RPC fail-closed semantics
```

Reproduce findings independently.

---

# 21. Deliverable

Return:

# Phase 2A — Authenticated Host/Principal Bridge

## Baseline

Exact starting state.

## Existing draft reuse

SAFE TO REUSE / REDESIGN / DEFER.

## Runtime topology

Processes and trust boundaries.

## Host authentication design

Exact platform evidence and role configuration.

## Host registration

Lifetime and generation model.

## AgentPrincipalReference

Fields and non-authority semantics.

## Principal validity RPC

Exact request/response semantics.

## End-to-end legitimate path

Show one real authorized agent operation succeeding.

## Revocation path

Show same reference failing after revoke.

## Host restart path

Show old generation failing.

## Impersonation tests

Same-user/process attacks and results.

## Cross-process product proof

Processes, commands, and result.

## Files changed

Exact list.

## Tests

Exact commands/counts.

## Broad regression gates

Must be green.

## Fresh-review findings

Reproduced findings only.

## Remaining Phase 2 blockers

Do not claim they are solved.

## Final status

Choose exactly one:

```text
PHASE 2A COMPLETE — HOST/PRINCIPAL BRIDGE PROVEN
PHASE 2A BLOCKED
```

Do not start the approval resolver work until this is green.