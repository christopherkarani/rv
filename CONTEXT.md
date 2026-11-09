# rv domain glossary

Terms the code and reviews use with one meaning. Add a term when a module is named after it.

## Secrets

**Secret definition** — one entry in `secrets.json` (or imported from a Varlock schema): a name, a **source** (where the value is read), a **delivery** (how it reaches a runtime), and optional expiry, refresh and binaries. `SecretDefinition`.

**Secret release** — the decision that lets a value leave its provider for one **release target**, and the shaping that goes with it: organization policy, gateway-only, expiry, the provider read, OAuth access-token unwrapping, AWS credential-set parsing, and the target's text rule. Every path that reads a secret value to hand it on goes through `SecretRelease.release(_:to:)`. All definitions are admitted before any is read, so a refused set reads, mints and prompts for nothing.

**Release target** — where a released value goes, each with its own organization rule and text rule. `SecretTarget`:
- *cage*: a contained runtime, by the definition's own delivery (environment variable, gateway placeholder, AWS signing).
- *stdio server*: a stdio MCP server, which holds the real value whatever the delivery says.
- *header*: an HTTP header rv sends from the host (remote MCP server, `audit forward`).

**Secret refusal** — why a release did not happen: invalid organization policy, an organization rule, gateway-only, expired, a provider failure, or an unusable value. Callers own the wording; the decision is the release's. `SecretRefusal`.

**Gateway-only** — a value that is not a lasting token (an AWS credential set, an OAuth access token the gateway keeps fresh). Only a cage's gateway may spend it; stdio servers and headers are refused.

**Lease** — what one launch gets from the launch broker: environment entries plus the gateway placeholders to revoke when the runtime ends. The broker builds a lease from released secrets.

## Guard

**Host mode** — how rv guards one hook host: `block` (enforce, the default), `observe` (allow and record what would have been blocked) or `off` (rv's hooks removed from that host). Stored under `guard.hosts` in `config.json`, `block` included, so an explicit `block` outranks a global `guard.mode: observe`; rvd resolves `RV_GUARD_MODE` > host mode > `guard.mode` > enforce, and an organization gate still pins enforce. `rv host list` reports each host's effective mode: a host with no entry reads as the global mode. A host set `off` before an organization gate arrived stays unwired (wiring `absent-file`, `managed_enforce: true`) until `rv setup` restores it. `HostMode`, `HostModeStore`.

**Observe floor** — what observe never relaxes: rv's own self-protection (an agent-issued rv command that weakens rv, `SelfProtectionGuard`) and rv's config dir (`core.secrets:home-rv-config`). On every door those stay enforced, so an observe host cannot loosen another host or the global guard. `ObserveFloor`.

**Observed block** — a denial-ledger row for an observe-mode evaluation that enforcement would have denied (`"observed": true`; `command.observed` in the audit trail). The agent was not blocked.

## Isolation

The module map is [`Sources/RVIsolation/README.md`](Sources/RVIsolation/README.md).

**Workspace** — one protected project folder while rv has it open. The agent writes to a private copy (on macOS, a disk-image volume mounted over the folder); nothing reaches the real folder until the workspace closes. `WorkspaceSessionID`, `WorkspaceSessionSupervisor`.

**Runtime** — one contained process tree inside a workspace, with its own process group, admission pipes and egress proxy. A workspace can host several; one runtime ending does not close the workspace. `RuntimeSessionID`.

**Backend** — what builds the walls for a runtime. `IsolationBackendFamily` has `.none`, `.seatbelt` (macOS), `.landlock` (Linux, compiled but refused before exec) and `.microvm`. Both VM guests are `.microvm`; `MicroVMGuest` picks `.linux` (`rv-microvm`) or `.macOS` (`rv-macvm`).

**Control path** — a workspace path that rv or git reads or runs later, outside any cage: `.git/hooks`, `.git/config`, `.rv`, `.config/rv`. `workspaceControlDenies`.

**Run-later path** — agent and editor config in the workspace that a host tool runs or trusts later, outside any cage: `.claude/settings.json`, `.mcp.json`, `.vscode/tasks.json`, `.envrc` and the like. `WorkspaceRunLaterPaths`.

Seatbelt, the macOS guest and the Linux guest (through read-only mounts) all stop a runtime from writing control paths and run-later paths. Seatbelt and the macOS guest also match case variants (`.MCP.json`); the Linux guest matches exact names only. Each backend also pins the directories on the way to a protected path (`.claude`, `.gemini/config`), so the cage cannot rename one aside and swap in a replacement.

**Publish** — copying the private copy back to the real folder when the workspace closes. All names are checked first; one rejected name publishes nothing. `WorkspacePublishOutcome`, `WorkspacePublishRejection`.

**Recovery** — finishing, on the next start, a close that a crash interrupted: publish, detach the volume, restore the original folder, each step recorded in the lifecycle log. `WorkspaceRecovery`, `WorkspaceRecoveryPlan`.

**Admission** — a runtime asking rv to run one command or one HTTPS GET on its behalf, over pipes only that runtime holds. `RuntimeAdmissionSession`.

**Egress proxy** — the per-runtime loopback proxy every outbound request goes through; it decides allow or deny with `EgressAdmission` against `EgressHostPolicy`. `EgressProxy`, `EgressWire`.
