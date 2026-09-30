# RV Agent Identity Specification v1

**Status:** Proposed source-of-truth architecture  
**Scope:** Agent identity, attestation, lifecycle, binding, delegation boundaries, and integration contracts  
**Baseline:** RV `9c546c994749ecbd9ff46322a7cc00d9cc715d47`  
**Reference research:** SPIRE `c1abb0ba7f3700bf859e6a1cab5ed8908ce79eb2`

---

## 1. Purpose

RV needs a trusted answer to:

> **Which agent is exercising this authority, and why does RV believe that identity?**

Agent Identity sits underneath Secrets, policy, approvals, audit, future MCP mediation, and future delegated/sub-agent authority.

It MUST NOT be implemented as:

- an agent name
- `HookHost`
- `SessionID`
- `RuntimeSessionID`
- a PID
- an executable path
- possession of a self-declared tag
- a secret-selection string
- a runtime capability alone

Those values may participate in the system, but none individually constitutes Agent Identity.

RV already separates runtime names from authentication: `RuntimeSessionID` is a name while `RuntimeCapability` authenticates admission requests.

Agent Identity formalizes the missing principal that those mechanisms operate on behalf of.

---

# 2. Core architectural decision

RV Agent Identity is **launch-bound identity**.

For RV-managed agents, identity is established by RV because RV:

1. receives the trusted launch request,
2. selects an Agent Definition,
3. resolves and verifies the workload,
4. creates the workspace/runtime context,
5. launches and supervises the process,
6. establishes executable evidence,
7. mints a fresh Agent Instance identity,
8. and only then grants that instance runtime authority.

RV therefore does not need to copy SPIRE's model of discovering the identity of an arbitrary process after that process connects.

SPIRE must identify strangers from kernel peer credentials and independently measured selectors. RV already owns the workload's creation path and knows its launch context before untrusted code executes.

The security principle RV adopts from SPIRE is:

> **The workload never gets to choose the trusted facts that establish its identity.**

SPIRE enforces this by deriving workload evidence itself rather than accepting PID, UID, path, or identity assertions from the workload.

RV MUST preserve the same invariant through its launch-controlled architecture.

---

# 3. Identity model

RV distinguishes four concepts.

## 3.1 Owner Principal

The human/account under whose authority RV operates.

For the current local product, this is anchored in the invoking OS user.

The Owner Principal is the root from which agent authority is delegated.

Agent Identity v1 does **not** attempt to defend against full compromise of the owning user account.

---

## 3.2 Agent Definition

An Agent Definition describes **what the operator intends to run**.

Examples conceptually include:

- Claude Code
- Codex
- OpenCode
- Hermes
- a user-defined agent
- an explicitly launched custom executable

An Agent Definition is stable across process launches.

It may define or reference:

- expected executable characteristics
- executable provenance requirements
- agent adapter/integration metadata
- resource profile
- permitted credential classes
- integration capabilities
- product metadata

An Agent Definition ID is a **name**, not authentication.

The definition MUST originate from trusted RV/operator configuration, not from the contained workload.

---

## 3.3 Agent Definition Revision

A material change to the security-relevant definition produces a different definition revision.

Security-relevant changes include at least:

- executable requirement
- signing requirement
- expected digest where applicable
- resource/credential bindings
- integration identity rules

This permits a stable conceptual identity such as `claude` while still recording exactly which definition produced a particular execution.

The revision MUST be immutable once an Agent Instance is created.

---

## 3.4 Agent Instance

An Agent Instance is the **actual security principal**.

It represents one concrete execution of an Agent Definition.

A new Agent Instance MUST receive a fresh unguessable instance identifier.

An Agent Instance binds at minimum:

```text
Owner Principal
      ↓
Agent Definition + Revision
      ↓
Agent Instance
      ├── WorkspaceSessionID
      ├── RuntimeSessionID
      ├── executable evidence
      ├── process-group lifetime
      ├── runtime capability binding
      └── optional parent/delegation context
```

The Agent Instance is ephemeral.

Today RV's natural lifetime boundary is already:

> one `RuntimeSessionID` = one spawned process group = one admission binding = one credential-staging set.

Agent Identity v1 adopts that execution boundary while keeping the semantic concepts separate.

Therefore:

> **One new process group means one new Agent Instance.**

A restarted process is a new Agent Instance even when it uses the same Agent Definition.

---

# 4. Names are never credentials

The following MUST remain identifiers or metadata only:

- Agent Definition ID
- Agent Instance ID
- RuntimeSessionID
- WorkspaceSessionID
- WorkspaceHostID
- HookHost
- SessionID
- PID
- PGID
- MCP tool name
- executable path
- agent tag

Possessing or controlling any of these values MUST NOT, by itself, grant authority.

This extends an invariant RV already follows correctly for runtime admission: the claimed session is checked only after the caller proves possession of the runtime capability.

---

# 5. Identity, attestation, authorization and credentials are separate

RV MUST preserve four separate layers.

## Identity

> Who is acting?

Answer: an Agent Instance.

## Attestation

> Why does RV believe that Agent Instance corresponds to the workload it claims?

Answer: RV-controlled launch facts and executable evidence.

## Authorization

> What may this Agent Instance do?

Answer: RV policy evaluation.

## Credential / capability

> What proves that a particular request belongs to that authenticated execution?

Examples:

- `RuntimeCapability`
- future scoped secret capability
- future delegated capability

A `RuntimeCapability` therefore does **not** become Agent Identity.

It is a credential issued to an already-established Agent Instance.

The current code already models this separation reasonably well.

---

# 6. Trusted launch sequence

The normative launch sequence is:

```text
trusted operator / RV
        │
        ▼
select Agent Definition
        │
        ▼
resolve definition revision
        │
        ▼
resolve intended executable
        │
        ▼
establish executable evidence
        │
        ▼
prepare workspace + containment
        │
        ▼
spawn workload under RV control
        │
        ▼
verify actual launched workload
        │
        ▼
mint Agent Instance
        │
        ▼
bind RuntimeSession
        │
        ▼
issue runtime capability
        │
        ▼
make privileged resources available
        │
        ▼
resume normal execution
```

**Authority-bearing capabilities and identity-scoped secrets MUST NOT become usable before identity establishment succeeds.**

Failure at any identity-establishment stage MUST fail closed.

---

# 7. Executable identity

The current RV implementation does not satisfy this requirement yet.

Today RV resolves an executable path, stores the path as a string, later launches `/bin/sh`, and the shell performs another path-based `exec`. There is no executable hash, code-signing verification, or atomic binding between the previously resolved file and the final image.

Agent Identity v1 therefore requires:

> **The actual executing workload MUST be bound to the executable requirements authorized by the Agent Definition.**

An executable path alone is insufficient.

---

## 7.1 Executable evidence

RV's executable evidence model MUST be capable of representing:

- canonical path
- device/inode evidence
- content digest
- platform code-signing evidence where available
- code identifier
- Team ID where available
- designated/explicit code requirement where applicable
- interpreter identity for script-based agents
- script/content identity where applicable
- PID + start-time evidence for the launched process

The identity model MUST store evidence as facts.

Policy decides which facts are required.

---

## 7.2 Signed agents

For signed macOS workloads, RV SHOULD support validation of the **actual live process image**, not merely static validation of a path before launch.

Relevant macOS primitives identified by the research include dynamic `SecCode` validation, signing information, Team ID and requirement checks.

A signature does not itself define the Agent Instance.

It is evidence supporting the binding between the Agent Definition and the launched workload.

---

## 7.3 Unsigned and ad-hoc workloads

Unsigned or ad-hoc agents remain supported.

They MUST NOT be forced into pretending to possess a signing identity they do not have.

Their executable requirements may instead rely on stronger combinations of content/object evidence such as:

- exact digest
- pinned executable object
- operator-approved immutable measurement
- interpreter + script measurements

The exact mechanism is an implementation decision, but the security property is not:

> A user-writable executable MUST NOT be able to change between authorization and execution while retaining the previously established Agent Identity.

If RV cannot prove that property for a launch mode, it MUST NOT claim strong executable attestation for that instance.

---

# 8. Runtime capability binding

Once the Agent Instance is established, RV may mint its runtime capability.

The runtime capability MUST be bound to:

- Agent Instance
- RuntimeSessionID
- WorkspaceSessionID
- runtime lifetime

A valid capability presented with a mismatched session or instance MUST fail authentication.

Copied capability material MUST become useless when the Agent Instance finishes.

RV already implements important parts of this behavior through capability matching, session claims, replay resistance and `finish()` semantics.

Agent Identity makes the principal binding explicit.

---

# 9. Agent Instance immutability

After establishment, the following properties MUST NOT mutate in place:

- Agent Instance ID
- Agent Definition revision
- workspace binding
- runtime binding
- executable evidence
- parent/delegator identity
- owner identity

A material change requires a new Agent Instance.

Examples:

```text
process restart        → new Agent Instance
different executable   → new Agent Instance
different agent def    → new Agent Instance
different workspace    → new Agent Instance
new process group      → new Agent Instance
```

Terminal attachment does not create a new Agent Instance.

---

# 10. Runtime reuse and reattachment

Current `ensureTerminalRuntime` behavior is principal-blind: it reuses the first running terminal regardless of requested executable, hook, arguments or resource profile, preserving the existing runtime's grants.

That behavior cannot remain ambiguous once identity exists.

Normative rule:

> **Reattachment may attach to an existing Agent Instance, but it MUST NOT relabel or mutate that Agent Instance.**

If the caller requests a different Agent Definition or incompatible security-relevant definition revision, RV MUST NOT silently reuse the runtime as though it belonged to the requested principal.

RV MUST either:

- return the existing instance explicitly as the existing principal,
- create another runtime/Agent Instance,
- or reject the request.

Reattachment MUST never result in a caller gaining a more privileged identity simply because another runtime already exists.

---

# 11. Agent tags and HookHost

`HookHost` and agent tags are integration metadata.

They are not principals.

They MUST NOT independently:

- alter an authorization result,
- select secret material,
- select credentials,
- resolve approvals,
- widen policy,
- identify the caller.

This fixes two concrete existing problems.

Current `HookHost` is self-declared yet can change a mandatory-human result into a quiet allow for certain host selections.

Current agent tags also participate in credential selection without proving that the runtime is actually the corresponding agent.

Agent Identity v1 requires all such selections to originate from the authenticated Agent Principal.

---

# 12. External / non-RV-launched agents

RV-managed contained agents and arbitrary host processes are different trust cases.

## RV-managed workload

RV controls launch.

Identity is **launch-bound**.

## External workload

RV did not create the process.

Identity must therefore be **observed/attested** from trusted platform evidence.

An external process MUST NOT become an authenticated Agent Principal merely by sending:

```text
--host codex
```

or:

```text
session = "foo"
agent = "claude"
```

If RV cannot securely establish the external workload's identity, it must treat host/agent claims as untrusted metadata.

Host-specific policy MUST NOT become less restrictive based solely on self-declared metadata.

The existing hook→rvd path currently authenticates no caller process and accepts caller-supplied host/session values.

That must not remain an identity boundary.

Agent Identity v1 does **not** require that external/uncontained agents receive the same assurance as RV-managed workloads.

---

# 13. Threat model

Agent Identity v1 protects against an adversarial agent attempting to:

- impersonate another agent
- select another agent's credentials
- change its host type to receive weaker policy
- reuse another runtime's identity
- replay another runtime's identifiers
- survive identity expiration
- retain authority across restart
- escalate through child execution
- manipulate approvals belonging to another principal
- claim a privileged MCP/tool identity
- cause audit records to attribute its action to another principal

The agent executable and everything it emits are untrusted.

Trusted components include RV's supervisor/control components, kernel enforcement, operator-authored security configuration and explicit human decisions. This matches the existing runtime threat model.

Full compromise of the owning OS user remains outside Agent Identity v1.

---

# 14. Approvals

Approvals MUST bind to an authenticated principal.

An approval record must reference at minimum:

```text
Agent Instance
+
action fingerprint
+
workspace/context required by policy
```

`HookHost + SessionID` MUST NOT be the authentication root for an approval.

Current approval identity is based on caller-supplied names, and the current XPC service exposes pending resolution/rule operations without caller authentication.

Human approval is a separate principal/authority boundary.

Resolution of an approval MUST require an authenticated human/control-plane authority.

An agent MUST NOT be able to resolve its own ASK merely because it knows:

- ApprovalID
- SessionID
- HookHost
- action fingerprint
- command
- cwd

---

# 15. Policy binding

Agent Identity does not replace policy.

Policy receives an authenticated principal as trusted context.

Conceptually:

```text
Authenticated Principal
        +
Proposed Action
        +
Trusted Runtime Context
        +
Policy
        ↓
ALLOW / ASK / DENY
```

Agent-provided fields may describe requested actions, but they MUST NOT override trusted principal facts.

The existing `RuntimeAdmissionSubject` approach—trusted frame plus normalized untrusted request—is the pattern to preserve.

The separate question of whether production `HostAdmission` should use `.empty` policy is **not defined by Agent Identity**. The current behavior is now understood: the built-in hard wall remains active, built-in ALLOWs execute, and ASK outcomes pend forever because no approval callback exists.

---

# 16. Delegation

Agent Identity v1 MUST support delegation semantically even if initial product flows do not expose user-visible sub-agents.

Delegation is **not credential copying**.

A parent principal may cause RV to create a child principal.

The child MUST have:

- its own Agent Instance ID
- its own runtime/capability binding where independently mediated
- an explicit parent/delegator reference
- authority less than or equal to its parent's delegable authority

Authority MUST only narrow.

```text
Parent Agent Principal
        │
        │ delegates subset
        ▼
Child Agent Principal
```

A child may never obtain authority merely because it knows the parent's identity or capability value.

RV MUST NOT copy SPIRE's older delegation behavior of handing the target's full identity credential to a delegate. SPIRE's research showed that this is effectively impersonation rather than chained delegation.

---

# 17. Ordinary subprocesses

Not every subprocess becomes a new Agent Principal.

An ordinary child process executing inside the same runtime process group remains part of the parent Agent Instance unless RV explicitly promotes it into an independently mediated principal.

Therefore:

```text
agent
  ├── shell helper
  ├── compiler
  ├── git
  └── ordinary subprocess
```

may all execute under one Agent Instance.

But:

```text
agent
  └── independently authorized sub-agent
```

must receive a distinct principal if RV gives it independently scoped authority.

This prevents every Unix subprocess from exploding the identity model while preserving correct delegation boundaries.

---

# 18. Secrets integration contract

Secrets MUST depend on Agent Identity.

Agent Identity MUST NOT depend on Secrets.

Secrets must be able to ask:

```text
Who is requesting authority?
Which Agent Definition?
Which Agent Instance?
Which workspace?
Which runtime?
How was it attested?
Who delegated to it?
Is the principal still alive?
```

Secret selection MUST NOT use a caller-supplied agent tag as authentication.

The current agent-tag credential selection path therefore must eventually be replaced by principal-bound selection.

Secrets MUST be revocable by ending the Agent Instance/runtime binding.

Delegated secret authority MUST be equal to or narrower than the parent's authority.

---

# 19. MCP/tool integration contract

A tool name is never an identity.

For future MCP integration RV must preserve both:

```text
calling Agent Principal
```

and, when relevant:

```text
target workload/service identity
```

An MCP server may eventually be:

- an RV-managed workload with its own principal,
- an externally attested workload,
- or an untrusted endpoint.

Those are not equivalent.

Direct loopback reachability currently carries no runtime identity at all.

Therefore identity-sensitive or secret-bearing MCP flows MUST NOT rely purely on loopback reachability.

The exact MCP transport design is outside this specification.

---

# 20. Audit contract

Every security-relevant event SHOULD be attributable to an Agent Instance rather than an arbitrary host/tag/session string.

Audit records for authenticated agent actions must be capable of including:

- Agent Instance ID
- Agent Definition ID + revision
- RuntimeSessionID
- WorkspaceSessionID
- owner
- parent/delegator where applicable
- executable evidence summary
- action fingerprint
- policy result
- approval actor where applicable
- lifecycle state

Sensitive secret values MUST never be recorded.

The audit principal is descriptive only; possessing an audit identifier grants no authority.

---

# 21. Revocation and lifetime

An Agent Instance's authority ends when its runtime identity ends.

At minimum:

```text
process group terminated
       ↓
runtime binding finished
       ↓
runtime capability invalid
       ↓
Agent Instance inactive
       ↓
instance-scoped authority unavailable
```

A new runtime/process group receives a new Agent Instance.

No identity survives restart implicitly.

Stable relationships across restarts come from the Agent Definition, not Agent Instance reuse.

---

# 22. Machine identity

Machine identity is not required for Agent Identity v1.

RV currently has no trustworthy hardware-bound machine identity primitive in use, and no identified local consumer requires one.

The core model MUST leave room for a future machine/organization principal without making it a prerequisite today.

---

# 23. Platform model

The semantic identity model is platform-independent.

Platform-specific attestation evidence is not.

## macOS

May use:

- RV-controlled spawn
- process-group/start-time facts
- vnode evidence
- code-signing evidence
- dynamic code validation
- launch nonce
- runtime capability

## Linux

Future Linux implementation may use:

- pidfd
- `SO_PEERCRED`
- `/proc` executable facts
- filesystem/content measurements
- RV-controlled launch
- runtime capabilities

Platform evidence MUST map into the same semantic principal model.

Linux support must not redefine what an Agent Instance means.

---

# 24. SPIRE concepts intentionally not adopted

Agent Identity v1 does not require:

- SPIFFE ID URI syntax
- trust domains
- X.509 SVIDs
- JWT SVIDs
- WIT-SVIDs
- CA hierarchy
- node attestation plugin fleets
- federation
- registration-entry synchronization
- timed SVID rotation

Those mechanisms solve distributed trust problems RV does not currently have.

If RV later needs cross-machine workload authentication, the identity model may gain an external credential representation without changing what an Agent Principal means.

---

# 25. Mandatory security invariants

These are normative.

### I1 — Names never authenticate

No UUID, tag, host name, PID, tool name or session string grants authority by itself.

### I2 — Agents cannot self-assign trusted identity

Trusted principal properties come from RV or independently trusted platform evidence.

### I3 — Authority follows identity establishment

No identity-sensitive secret or privileged capability becomes available before required attestation succeeds.

### I4 — Actual workload must satisfy the authorized executable requirement

Path strings alone are insufficient.

### I5 — Instance identity is immutable

Changing security-relevant execution identity produces a new Agent Instance.

### I6 — Runtime capabilities are principal-bound

A capability cannot be moved to another Agent Instance.

### I7 — New execution means new instance

Restart/new process group creates a fresh Agent Instance.

### I8 — Reattachment cannot relabel

Attaching to an existing runtime does not change its identity or grants.

### I9 — Derived authority only narrows

Children/delegates can receive no more than the delegator may delegate.

### I10 — Secret selection uses authenticated principal

Never self-declared agent tags.

### I11 — Host-specific policy uses authenticated principal

Never self-declared `HookHost`.

### I12 — Approval resolution is authenticated

Knowledge of approval identifiers is insufficient.

### I13 — Agent-provided bytes never become trusted frame facts

Principal/workspace/policy context comes from RV-held state.

### I14 — Identity failure fails closed

Unknown, ambiguous, stale or unverifiable identity never widens authority.

### I15 — Audit attribution follows authenticated principal

Agent-controlled labels are supplemental metadata only.

---

# 26. Acceptance criteria

Agent Identity v1 is not complete until tests prove at least the following.

### Identity creation

- A new runtime process group receives a fresh Agent Instance.
- Restarting the same agent receives a new Agent Instance.
- Reattaching to the same runtime retains the same Agent Instance.
- Agent Definition and Agent Instance are distinguishable in audit/state.

### Impersonation

- Changing `HookHost` cannot obtain another agent's policy behavior.
- Changing an agent tag cannot obtain another agent's credentials.
- Providing another Agent Instance ID without its valid binding grants nothing.
- Another runtime cannot use another instance's runtime capability.

### Executable binding

- Swapping an executable between resolution and execution cannot preserve the previously authorized attested identity.
- A signing-requirement mismatch fails closed.
- A content/digest requirement mismatch fails closed.
- Script/interpreter identity cannot collapse into an unverified path string.

### Runtime reuse

- A request for a different Agent Definition cannot silently relabel an existing terminal.
- A request for stronger grants cannot widen an existing reused runtime.
- Reattachment exposes the existing principal explicitly.

### Approvals

- An agent cannot resolve its own pending approval.
- One Agent Instance cannot resolve another Agent Instance's approval.
- Knowledge of pending IDs/fingerprints/session names is insufficient.
- Human approval remains consume-once where required.

### Delegation

- Child authority can be narrower than parent authority.
- Child authority cannot exceed parent/delegable authority.
- Child gets a distinct principal where independently mediated.
- Parent/child relationship appears in audit.
- Parent credential copying is not used as delegation.

### Secrets contract

- Credential selection is based on authenticated principal.
- A self-declared agent tag cannot widen secret access.
- Ending the Agent Instance invalidates instance-bound secret authority.
- Another workspace/runtime cannot reuse the terminated instance's secret authority.

### Failure behavior

- Missing executable evidence fails closed when required.
- Ambiguous identity fails closed.
- Stale capability fails closed.
- Principal mismatch fails closed.
- Identity establishment failure produces no privileged capability.

---

# 27. Explicitly deferred decisions

These are implementation/product decisions, not missing identity semantics:

- exact Swift type names
- persistence format
- exact executable-measurement implementation
- exact mechanism for secure external-agent attestation
- whether the hook transport remains XPC
- exact Secrets API
- exact MCP mediation transport
- organization identity
- remote/fleet identity
- hardware machine identity
- PKI/SVID support
- Linux implementation timing

These decisions may change without changing the Agent Identity model defined here.

---

# 28. Architectural summary

RV's identity chain is:

```text
Owner
  │
  ▼
Agent Definition
  │
  │ trusted selection
  ▼
Executable Requirement
  │
  │ RV-controlled attestation
  ▼
Agent Instance
  │
  ├── Workspace
  ├── Runtime
  ├── executable evidence
  └── parent/delegator
  │
  │ issue
  ▼
Runtime Capability
  │
  ▼
Authenticated Action
  │
  ├── Policy
  ├── Approval
  ├── Secrets
  ├── MCP / tools
  └── Audit
```

The central invariant is:

> **RV, not the agent, establishes who the agent is. Authority is then issued to that established principal and can only narrow from there.**
