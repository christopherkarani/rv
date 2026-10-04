Continue in the **current coding-agent session and current `phase-2Identity` working tree**.

Do not reset the branch.

Do not discard Phase 2A / Phase 2A.1 work.

Do not start Phase 2B.

The next task is:

# Phase 2A.2 — Scoped Operator Launch Authorization

The current blocker is:

> Identity-aware launch selection and real AgentInstance creation exist, but the real workspace operator launch request is refused by `WorkspaceOperationAuthorization` before trusted definition selection and launch can occur.

The objective is to make **one legitimate operator-authorized identity launch** reachable through the real product path without weakening RV's authorization model.

---

# 1. Scope

Implement only enough operator/control authorization to permit the identity-aware launch operation safely.

The intended path is:

```text
authenticated operator/control client
    ↓
operation-scoped authorization
    ↓
workspace host
    ↓
trusted AgentDefinition selection
    ↓
WorkspaceSessionSupervisor.launchAgent
    ↓
real AgentInstance
    ↓
AgentPrincipalReference
    ↓
authenticated workspace-host ↔ rvd bridge
    ↓
one legitimate agent evaluation
```

Do not implement general human approval resolution.

Do not implement Phase 2B.

---

# 2. Preserve current state

Before editing report:

```text
branch
HEAD
working-tree status
current Phase 2A / 2A.1 dirty files
focused test counts
broad gate status
```

Create a recoverable snapshot/checkpoint before modifying files.

Preserve `Vendor/`.

Do not squash or rewrite existing Phase 2 research yet.

---

# 3. Ground-truth the refusal

Trace the exact real product call chain that currently rejects:

```text
rv workspace agent <definition-id> -- ...
```

Identify:

- CLI call
- workspace client operation
- wire message
- server dispatch
- `WorkspaceOperationAuthorization`
- exact refusal condition
- what authenticated peer context is available at that point
- whether the request reaches the host before denial
- what authority would be required to permit it safely

Do not guess from the previous report.

Show exact source symbols.

---

# 4. Define operator launch authority

Create a narrow operation-scoped authorization concept.

It must answer:

> Is this authenticated control caller authorized to request **this exact workspace launch operation**?

It must not mean:

```text
same UID == operator
signed rv == human
has workspace owner token == operator
knows workspace ID == operator
TTY == operator
```

Separate:

```text
authenticated RV component
workspace endpoint/correlation ownership
operator/control authority
Agent Principal
human approval authority
```

These are distinct.

---

# 5. Do not use LocalAuthentication yet

This operation is not the Phase 2B human approval resolver.

Do not pull in:

```text
LAContext
Touch ID approval
pending approval resolution
rule save
allow-once human decision
```

unless the locked spec explicitly requires fresh human presence for launching an agent.

For this step, implement the smallest legitimate **control-plane/operator authorization** mechanism consistent with the current architecture.

If the architecture cannot safely authorize the launch without solving the human authority problem, stop and report that as a blocker instead of inventing a weaker mechanism.

---

# 6. Prefer existing authenticated control context

The Phase 2 draft already has peer-authentication primitives and role separation.

Reuse trustworthy foundations where appropriate.

The operator launch authorization should originate from:

```text
authenticated transport peer
+
trusted component/control role
+
workspace-specific scope
+
specific operation
```

It must not be constructed from arbitrary decoded payload fields.

Prefer an internal non-wire authorization value such as:

```text
WorkspaceControlAuthorization
```

or equivalent existing architecture.

It should be created only at a trusted boundary.

---

# 7. Authorization scope

Bind the authorization to at least:

```text
caller connection / authenticated peer
workspace
operation = launchAgent or launchCustom
request identity / nonce where useful
lifetime
```

For named-agent launch also bind:

```text
requested AgentDefinitionID
```

For custom launch bind:

```text
absolute executable intent
expected digest intent
```

Do not create a reusable:

```text
isOperator = true
```

that can later authorize:

- cancel
- close
- policy mutation
- approvals
- Secrets
- arbitrary workspace actions

unless those operations are independently scoped and explicitly intended.

---

# 8. Connection lifetime

Authorization must die when its authenticated control connection dies.

Do not persist it as reusable disk authority.

Do not allow replay after:

```text
client disconnect
workspace-host restart
host generation change
authorization expiry
operation consumption
```

If the design is consume-once, test consume-once.

If it is per-connection scoped, document exactly what operations it permits.

---

# 9. Workspace owner token

The existing workspace owner token may remain:

```text
endpoint correlation
workspace possession proof
launch routing metadata
```

but it must not independently produce operator authority.

Prove:

```text
copied owner token + same UID + unauthenticated process
→ cannot launch identity-aware agent
```

---

# 10. Legitimate CLI path

Wire the real CLI launch command through the scoped authorization mechanism:

```text
rv workspace agent <definition-id> -- <args>
```

and where appropriate:

```text
rv workspace custom --expected-content-digest-sha256 ... -- /absolute/executable ...
```

Do not introduce a test-only bypass.

The actual product CLI must use the same authorization route exercised by tests.

---

# 11. Successful identity launch

Once authorization succeeds, verify the existing 2A.1 path remains unchanged:

```text
trusted definition selection
→ ResolvedAgentLaunch
→ launchAgent
→ AgentInstance announced
→ runtime binding
→ established
→ active
```

Do not modify definition trust semantics merely to make authorization easier.

Do not derive definitions from the control authorization.

---

# 12. Real bridge success is mandatory

After making the launch reachable, immediately attempt the missing end-to-end oracle.

Required real topology:

```text
rvd process
workspace-host process
runtime/agent process
```

Required sequence:

```text
authenticated operator launch
→ real AgentInstance
→ host registration with rvd
→ host-issued AgentPrincipalReference
→ live validity RPC
→ ServiceValidatedAgentContext
→ one legitimate agent evaluation
→ successful normal result
```

This is the main acceptance test.

Do not stop after proving that launch authorization alone works.

---

# 13. Choose a safe allowed operation

Select an agent operation that the existing semantic/hard-policy engine legitimately permits.

Do not:

```text
weaken hard policy
insert temporary allow rule
consume an owner grant just to make the oracle green
bypass normal evaluation
```

The oracle must prove normal authenticated success.

---

# 14. Revocation oracle

After the successful service operation:

1. keep the same real `AgentPrincipalReference`
2. revoke or terminate the AgentInstance
3. repeat the same service operation

Expected:

```text
FAIL CLOSED
```

Prove the service-side live principal validation rejects it.

---

# 15. Host restart oracle

After successful service use:

1. terminate the workspace host
2. start a fresh host incarnation
3. retain the old reference
4. retry

Expected:

```text
old WorkspaceHostGeneration → FAIL CLOSED
```

A fresh launch must use a fresh host generation.

---

# 16. Unauthorized launch attacks

Add real negative tests:

### Same-user rogue process

A separate process with:

```text
same UID
workspace ID
socket path
owner token if obtainable
AgentDefinitionID
```

must not launch.

### Signed/trusted CLI without control scope

Being a recognized RV executable alone must not imply authorization to any arbitrary operation beyond its assigned control role/scope.

### Replayed launch authorization

Old authorization must fail after its lifetime/connection/request is gone.

### Cross-workspace use

Authorization scoped to workspace A cannot launch into workspace B.

### Operation substitution

Authorization for:

```text
launchAgent A
```

cannot become:

```text
launchAgent B
launchCustom
cancel
close
policy mutation
```

---

# 17. Component trust dependency

The latest 2A.1 report says installed trusted component-role provisioning remains unproven.

If the real three-process oracle cannot proceed without administrator installation of:

```text
/Library/Application Support/RV/peer-trust.json
```

use the existing explicit administrator provisioning mechanism.

Do not add a writable fallback.

If administrator credentials are unavailable in the execution environment:

- do not fake authentication,
- clearly separate authorization code success from installed trust proof,
- return BLOCKED.

But first determine whether the current authenticated development setup can exercise the real control/host/service chain without weakening security.

---

# 18. Do not expand into general workspace permissions

This task is specifically:

```text
identity-aware launch authorization
```

Do not complete every workspace-control operation.

Other operations may remain refused.

If needed, define a method-role matrix entry only for:

```text
launchAgent
launchCustom
```

and leave unrelated mutations closed.

---

# 19. Broad regression failures

Current inherited failures include:

```text
RVDomainTests approval expectations
RVPolicyTests approval expectations
RVIsolationTests refusal-boundary/control fixtures
RVServiceTests DenialLedgerRecord crash
```

Do not fix unrelated approval semantics in this pass unless a failure is directly caused by the new launch authorization.

But after implementation classify every relevant failure as:

```text
INHERITED
INTRODUCED
RESOLVED
```

No new broad failure is acceptable.

---

# 20. Tests

Add targeted tests for:

```text
authorized named launch succeeds
authorized custom launch succeeds where supported
unauthorized launch refuses
owner token alone refuses
same UID alone refuses
wrong workspace refuses
wrong definition refuses
operation substitution refuses
authorization replay refuses
connection loss invalidates authorization
legacy launch remains legacy
authorized launch mints real AgentInstance
real host issues reference
rvd validates real reference
real service evaluation succeeds
revoked instance fails same operation
old host generation fails
```

Prefer real transports/product paths for security claims.

Mocks may test pure state transitions, but they cannot be the only proof.

---

# 21. Cross-process evidence

For the successful oracle capture:

```text
rvd PID
workspace-host PID
runtime PID
authenticated peer roles
WorkspaceHostID
WorkspaceHostGeneration
AgentInstanceID
RuntimeSessionID
WorkspaceSessionID
```

Do not output:

```text
RuntimeCapability
owner token
secret values
private auth material
```

---

# 22. Fresh reviewer

After implementation, use a **new agent/session for review**.

Do not use the current implementation agent as the only reviewer.

Give the reviewer:

- spec
- final diff
- operator authorization model
- launch call chain
- successful cross-process oracle
- negative tests

Do not give implementation rationale.

Ask it to find:

```text
same-UID privilege escalation
owner-token escalation
signed-rv == human mistakes
cross-workspace replay
operation-scope widening
authorization replay
payload-created control authority
definition substitution
legacy-to-principal upgrade
service oracle bypassing real host validation
```

Independently reproduce any finding.

---

# 23. Validation

Run:

```sh
Scripts/preflight.sh

Scripts/swift-6.4 test --filter RVDomainTests
Scripts/swift-6.4 test --filter RVPolicyTests
Scripts/swift-6.4 test --filter RVIsolationTests
Scripts/swift-6.4 test --filter RVIPCTests
Scripts/swift-6.4 test --filter RVServiceTests
```

Also run the product oracle separately.

Report exact:

```text
commands
counts
failures
process topology
platform
trust configuration
```

Do not count a skipped/blocked installed-auth test as PASS.

---

# 24. Stop conditions

Stop and return `BLOCKED` if any of these is true:

```text
safe operator authority requires general human authentication design
component trust cannot be provisioned or exercised
real three-process authenticated success cannot be achieved
valid launch requires weakening peer authentication
same-user process can acquire control scope
owner token becomes operator credential
new broad regressions appear
```

Do not work around these conditions.

---

# 25. Deliverable

Return:

# Phase 2A.2 — Scoped Operator Launch Authorization

## Baseline

Current branch/HEAD/tree.

## Refusal root cause

Exact previous gate and code path.

## Authorization model

What establishes operator/control authority and what does not.

## Scope/lifetime

Workspace, operation, request and connection binding.

## Legitimate product launch

Exact real CLI → host → supervisor path.

## AgentInstance result

Real IDs/binding/assurance summary.

## Cross-process service success

Actual:

```text
rvd + workspace-host + runtime
```

result.

## Negative authorization tests

Same UID, owner token, wrong workspace, replay, substitution.

## Revocation oracle

Success before revoke / failure after revoke.

## Host restart oracle

Old generation rejection.

## Files changed

Exact list.

## Tests

Exact commands/counts.

## Broad gates

Classify all as GREEN / INHERITED / NEW.

## Fresh-review findings

Reproduced findings only.

## Remaining Phase 2A blockers

Especially trust provisioning, forwarding proof and broad suites.

## Final status

Choose exactly one:

```text
PHASE 2A.2 COMPLETE — SCOPED LAUNCH + REAL PRINCIPAL OPERATION PROVEN
PHASE 2A.2 BLOCKED
```

Do not start Phase 2B.