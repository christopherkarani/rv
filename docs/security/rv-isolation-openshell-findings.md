# rv isolation vs NVIDIA OpenShell: findings

Top finding: rv enforces process-level containment (macOS Seatbelt, deny-default) with hook-grade policy, while OpenShell enforces kernel- and network-level containment (Landlock + seccomp + `network_mode=none` + supervisor proxy) with formally checked policy. OpenShell's boundary is strictly stronger on Linux; rv's strengths are its restrict-only policy merge, fail-closed stores, and refusal to run a weak Linux sandbox.

All claims below are grounded in primary sources: rv source and `docs/security`, NVIDIA's OpenShell docs (v0.1.3) and the [NVIDIA/OpenShell](https://github.com/NVIDIA/OpenShell) repo. The existing `rv-vs-openshell.html` at the repo root is editorial, not evidence, and is not cited.

## 1. How rv isolation works

Contained plans are typed guarantees, not booleans: workspace-scoped filesystem, network denied, host signals denied, descent inherited (`Sources/RVDomain/Isolation.swift:70-77`). A backend that cannot establish every field must refuse the launch.

macOS enforcement compiles an `IsolationPlan` to Seatbelt SBPL (`Sources/RVIsolation/SeatbeltProfile.swift:958-1025`):

- `(deny default)` plus workspace read/write on the canonical path only.
- Read/execute baseline: `/usr`, `/bin`, `/sbin`, `/System`, `/Library`, `/dev`; content reads of `/etc/ssl` and tzdata; metadata-only elsewhere.
- Mach/XPC denied by default with one narrow allow (`com.apple.bsd.dirhelper`, required for SwiftPM linking).
- Signals to same-sandbox only; `setpgid`/`setsid` denied; `file-link`/`file-clone` denied; no Unix-socket rules (unscoped by Seatbelt, so refused).
- Loopback TCP connect plus loopback bind/listen/accept, so caged dev servers work.

Linux contained launch always fails closed: `compileLandlockRuleset` returns `containedGuaranteesUnsupported` rather than a write-only slice that would leave reads and network open (`Sources/RVIsolation/LandlockRuleset.swift:83-96`). The C shim handles write-class bits only and requires ABI 3 (`Sources/RVIsolation/LandlockRuleset.swift:23-29`).

Lifetime and identity hardening (`docs/security/runtime-boundary.md`):

- Each runtime gets its own process group, SIGKILLed on exit/cancel; Seatbelt establishment is proven by a pipe nonce, not the child exit status.
- Hard-link escape is closed by link-count preflight plus mounting the workspace on a private volume (`EXDEV` blocks post-preflight links); copy-back on close re-verifies device/inode/kind.
- Environment is projected through `ContainedEnvironmentPolicy`, which is deliberately default-allow with an aggressive denylist (`Sources/RVIsolation/ContainedEnvironmentPolicy.swift:13-24`); the spawn boundary sets runtime-owned `PATH`/`HOME`/`TMPDIR`.
- A separate admission broker lets a contained payload ask RV to run one shell command or one public HTTPS GET over capability-bound pipes; the pipes and unguessable capability bind the action, never the session id alone.

## 2. How rv sets policy for isolation

Policy is layered TOML with code-level merge semantics:

- Layers are builtin, machine (`~/.config/rv/policy.toml`), and repo (`.rv/policy.toml`) (`Sources/RVPolicy/RVPolicyPaths.swift:52-54`, `Sources/RVPolicy/TypedRuleStore.swift:53-80`). Config dir derives from process `HOME` only, never `XDG_CONFIG_HOME`.
- Merge is restrict-only: later layers may tighten (`deny > ask > allow`) but never drop an earlier deny or ask (`Sources/RVPolicy/TypedRuleStore.swift:122-166`). Safety level is strict-wins across machine and repo (`Sources/RVPolicy/PolicyWorkspace.swift:89-94`).
- CLI surface is `rv policy show | validate | export | apply` plus draft (`Sources/RVCLI/Commands/PolicyCommand.swift:10-12`). There is no revision list, rollback, or base-vs-effective view.
- Enforcement-time overrides live in `PolicyGate`: allowlist, single-use allow-once grants (service memory only, never the file), rebase recovery, and balanced-profile reversible deletes. Pinned rules block all overrides; indeterminate evaluations never allow (`Sources/RVPolicy/PolicyGate.swift:31-77`).
- Network egress for contained runtimes goes through a host-side loopback CONNECT proxy. The Standard default is `publicHTTPS`: any valid public DNS name on ports 80/443, with a public-unicast dial filter that blocks loopback, private, link-local (including cloud metadata), and reserved ranges, so DNS rebinding buys no lateral capability (`Sources/RVDomain/EgressPolicy.swift:42-46,66-86`, `Sources/RVIsolation/EgressProxy.swift:64-73`). A narrow exact-host allowlist mode exists for agent APIs.
- Audit is a JSONL session log (`workspace-sessions.jsonl`) with create/close and runtime start/end lines; it records no policy id, capability set, or kernel-deny events (`docs/security/runtime-boundary.md:78`).

## 3. How OpenShell isolation and policy work

Enforcement (from `crates/openshell-driver-docker/README.md` on `main`):

- Two containers per sandbox. `openshell-sandbox` is PID 1 in the workload container: process tree, seccomp user-notification broker, mandatory Landlock baseline, binary identity, PTY. `openshell-supervisor` runs in a separate companion container: gateway session, policy engine, credentials, interception CA, SSH relay, L7 inspection, DNS policy, upstream connections.
- The workload uses `network_mode=none`. Every supported TCP and DNS operation is mediated by the seccomp broker, attributed to the calling binary, and sent over a private channel; the supervisor authorizes before opening upstream. Docker's absent workload network is the outer fence if mediation fails.
- Both containers are non-root, request no capabilities, and set no-new-privileges. The supervisor JWT and gateway credentials live on a supervisor-only volume never mounted into the workload, so the agent never holds real credentials.

Policy (from [Sandbox Policies](https://docs.nvidia.com/openshell/latest/how-it-works/policies/overview), [Network Rules](https://docs.nvidia.com/openshell/latest/how-it-works/policies/network-rules), [Default Policy](https://docs.nvidia.com/openshell/latest/how-it-works/policies/default-policy)):

- A policy is YAML with up to five sections: `filesystem_policy` (kernel Landlock, fixed at startup), `landlock` (startup failure mode), `process` (run-as user/group), `network_policies` (per-binary rules, hot-reloadable), `network_middlewares` (L7 inspection). Anything not allowed is denied.
- Each network rule lists endpoints (host + port, with L7 method/path restrictions for HTTP, GraphQL, MCP, WebSocket) and binaries by real executable path as the kernel reports it; rules extend to child processes, and executables are hash-pinned on first use.
- The restrictive default grants the workdir read-write, `/bin` `/usr` `/lib` `/proc` `/dev/urandom` `/etc` `/var/log` read-only, `/tmp` and `/dev/null` read-write, no network rules (all outbound denied), and a non-root identity.

Policy lifecycle (from [Manage Sandbox Policies](https://docs.nvidia.com/openshell/latest/how-it-works/policies/manage-policies), [Policy Prover](https://docs.nvidia.com/openshell/latest/how-it-works/policies/prover), [Policy Advisor](https://docs.nvidia.com/openshell/latest/how-it-works/policies/advisor), [Providers](https://docs.nvidia.com/openshell/latest/how-it-works/providers/overview)):

- Policy is set at `sandbox create --policy`, via `OPENSHELL_SANDBOX_POLICY`, or baked into the image at `/etc/openshell/policy.yaml`. Base policy (what you set) and effective policy (base plus provider-contributed rules) are inspectable separately; `policy list` shows every revision and whether the sandbox loaded it; rollback re-submits an earlier revision; a global policy can override per-sandbox policy.
- Filesystem/process settings are fixed at startup; `policy update` changes only `network_policies` on a running sandbox without restart.
- The prover is an SMT-solver check with two modes: boundary check (candidate policy allows nothing beyond a boundary policy, with counterexample on failure) and proposal risk check (a proposed rule adds no risky access such as cloud-metadata or new credential destinations). It refuses to check policies using features outside its model instead of silently ignoring them.
- The advisor (off by default) lets a blocked agent propose a scoped network rule over a local HTTP API. Proposals never self-apply; by default each waits for human review, with opt-in auto-approval only when risk checks pass. OpenShell also auto-drafts proposals from blocked connections.
- Providers are first-class credentials injected at approved endpoints only, with per-profile endpoint/binary metadata and refresh behavior.

## 4. Comparison

| Concern | rv | OpenShell |
|---|---|---|
| Filesystem fence | Seatbelt `subpath` (macOS); Linux refused | Landlock baseline in kernel, mandatory |
| Syscall mediation | Deny `setpgid`/`setsid` via SBPL | seccomp user-notify broker on TCP/DNS |
| Direct egress | None: loopback-only cage, host proxy dials | None: `network_mode=none`, supervisor dials |
| Net rule granularity | Host (+port); `publicHTTPS` is any public DNS | Per-binary + host + port + L7 method/path |
| Binary identity | Absolute-path argv validation | Kernel-reported real path + hash pinning |
| Credentials | Env denylist; no broker | Providers injected outside agent reach |
| Policy format | TOML layers, restrict-only merge | YAML sections, base vs effective views |
| Change control | show/validate/export/apply | Revisions, rollback, global policy, hot reload |
| Change verification | Schema validation | SMT prover: boundary + proposal-risk checks |
| Agent self-service | Allow-once grants, human approves | Advisor proposals, human approves by default |
| Audit | Session JSONL, no policy/deny events | Revision history with load status |
| Linux story | Refuses contained (fail closed) | Linux-first, four compute drivers |

## 5. What rv should borrow, in priority order

1. Close the Linux gap or keep refusing loudly. OpenShell's whole model is Linux-first (Landlock + seccomp + netns). rv's refusal is honest, but every Linux agent run today is unsandboxed. A Landlock full slice (read + write + truncated DNS/egress story) is the single biggest parity item.
2. Move from host-only egress to per-binary rules. rv's `publicHTTPS` admits any public DNS for any caged binary; OpenShell attributes each connection to its binary and can restrict method/path. Even binary-scoped host rules would shrink exfiltration paths.
3. Broker credentials instead of filtering environment. `ContainedEnvironmentPolicy` is default-allow with a denylist, which fails open on every new secret-bearing name. A provider-style model (creds live supervisor-side, injected at approved endpoints only) removes the whole class.
4. Add live network-rule updates with a review queue. OpenShell's `policy update` + advisor pattern maps cleanly onto rv's existing allow-once/approval machinery: agent proposes, risk check runs, human approves, no restart.
5. Add prover-style checks on policy diffs. rv validates schema; OpenShell proves containment against a boundary and flags risky grants. A lightweight version (new destinations, metadata/private ranges, credential-bearing endpoints) would catch the dangerous diffs.
6. Add revisions, rollback, and base-vs-effective views. rv has the merge semantics (restrict-only, strict-wins) but no history or provider-rule separation to debug "why is this allowed".
7. Fix measured residuals: LAN-listen overbroad (any loopback-listen rule also allows 0.0.0.0/LAN bind), shared host loopback with no per-workspace isolation, per-user tmp readability, and host process visibility. OpenShell answers these with unprivileged identity plus seccomp/container boundaries.

Keep: restrict-only merge, strict-wins safety, fail-closed stores, deny-default SBPL, inode/hardlink volume boundary. Those are genuinely strong and have no OpenShell equivalent weakness to fix.

## 6. Unresolved

- OpenShell's centralized audit-trail export format and retention were not confirmed: revision listing with load status was verified, but a centralized log sink and audit event schema were not inspected (the driver README mentions OTLP trace export, which is not the same claim).
- `architecture/sandbox.md` in the OpenShell repo 404'd on fetch; enforcement internals above come from the driver README and official docs instead.

