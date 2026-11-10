# Rule packs and MCP inside the micro-VM cage

Status: design, not started. Owner decisions are in section 12.
Scope: Linux micro-VM runtimes (`rv workspace run --microvm`). The macOS guest (`--macvm`) reuses the same design after Phase 2. Seatbelt cages get one fix (Phase 0).
Line numbers are against commit `bc52f30`.

## 1. What happens today

**Seatbelt cage.** The workload talks to RV over admission pipes. The handshake is on fd 3 and is closed before exec. Requests go on fd 4, grant and responses on fd 5 (`Sources/RVIsolation/RuntimeAdmissionSpawn.swift:9-15`, `Sources/RVIsolation/SessionSupervisor.swift:10-23`). For an instance-bound shell request, `HostRuntimeAdmission` asks rvd over the host bridge (`Sources/rv-workspace-host/HostAdmission.swift:35-38, :52-68`). Legacy channels with no Agent Instance skip rvd entirely (`subject.agent != nil`, `:36`).

**Only day-one packs apply.** The bridge client builds the request with `.makeDayOne(command:)` (`Sources/RVService/WorkspaceHostBridgeClient.swift:131`). That is `core.filesystem`, `core.git` and `system.disk` (`Sources/RVDomain/RVDomain.swift:7-10`, `Sources/RVDomain/EvaluationRequest.swift:73-75`). rvd then compiles and walks exactly `params.request.enabledPacks` (`Sources/RVService/ServiceRuntime.swift:506-517`, `Sources/RVService/GatedEvaluate.swift:548-560`). So the user's `rv packs enable cloud.aws` does nothing in any cage today. The hook door instead uses `EvaluationWorld.walkedPackIDs(home:)`, the effective set (`Sources/RVService/EvaluateWorld.swift:52-55`, `ServiceRuntime.swift:538-541`).

**Micro-VM.** Admission fds 4/5 are not forwarded. Nothing in the guest evaluates commands (`docs/security/runtime-boundary.md:1417`). Agent-definition launches are refused with `backendMismatch` (`:1410`), so a micro-VM runtime has no Agent Instance (`Sources/RVIsolation/WorkspaceSessionSupervisor.swift:1735-1741`). The guest reaches only two host services, both relayed:

```text
guest 127.0.0.1:P ─ rv-guest-relay ─ /run/rv/pP.sock ─ vsock ─ rv-microvm HostRelay ─ host 127.0.0.1:P
```

- `rv-guest-relay` is a static C binary running as container init, at most 8 pairs (`Sources/rv-guest-relay/rv_guest_relay.c:1-23, :43`). It ships in the read-only tools mount `/.rv` (`Packages/rv-microvm/Sources/RVMicroVMCore/MicroVMPins.swift:70-74`).
- `RelayPlan` maps ports to socket paths (`Packages/rv-microvm/Sources/RVMicroVMCore/RunOptions.swift:201-229`). `HostRelay` always dials host loopback TCP (`Packages/rv-microvm/Sources/rv-microvm/HostRelay.swift:68-74`). Only the egress proxy and secret gateway ports are relayed (`SessionSupervisor.swift:619-626`).
- The egress proxy authenticates each request with a per-runtime 256-bit credential (`Sources/RVIsolation/EgressProxy.swift:39-56`, minted in `WorkspaceSessionSupervisor.swift:1453-1465`). It reaches the guest as proxy URL userinfo through `RV_GUEST_` forwarding (`Sources/RVIsolation/MicroVMLaunch.swift:321-334`).

**MCP.** `rv mcp serve` is a stdio gateway that hosts launch as a subprocess (`Sources/RVCLI/Commands/MCPCommand.swift:1347-1348`, `Sources/RVMCP/MCPGatewayRuntime.swift:195-198`). It speaks streamable HTTP only as a client, to remote upstreams (`Sources/RVMCP/MCPRemoteTransport.swift:81-103`). A guest agent has no gateway. Its MCP servers would have to run inside the guest, with secrets in the guest and network through the proxy.

**Why it matters.** The VM stops a hostile guest from touching the host. It does not stop a cooperating agent from destroying remote state with credentials rv staged for it: `git push --force` over the proxy, `aws s3 rm --recursive` through the signing gateway, `terraform destroy`. Packs stop exactly those before they run.

## 2. Goals and non-goals

Goals:

1. A guest agent's own PreToolUse hook gets the same verdict the host hook would give: the user's effective packs, safety level, repo policy, script gate and judge.
2. Guest agents use host-side MCP gateway tools. Upstream secrets stay on the host.
3. Every guest request is authenticated to one runtime and one Agent Instance (identity spec §8, §19). Copied tokens die with the runtime (§21).
4. Fail closed. No reachable state turns into ALLOW.
5. Fix day-one-only evaluation for Seatbelt cages too.

Non-goals:

- Making a hostile guest call its hook. The guest is root in the VM (`runtime-boundary.md:1418`) and can edit or skip its own hook config. The hook is cooperative, as it is on the host.
- Allow-once inside the cage. The agent door never spends owner grants (`GatedEvaluate.swift:620-623`). Principal-bound grants need the owner action route (`docs/plans/owner-action-route/SPEC.md`).
- Running rvd inside the guest (`docs/plans/vm-isolation/PLAN.md:76, :128`). See option (d).

## 3. Threat model

The guest is untrusted. Any guest process can read the guest environment (and with it every token), connect to every relayed port, fork, and write the workspace, whose files publish on close. All guest processes count as one Agent Instance (identity spec §17).

Host processes running as the same user are outside the model (identity spec §13). We still do not rely on reachability alone (§19), because host loopback TCP is reachable by every local user.

Guaranteed:

- A guest cannot get an evaluation or MCP call attributed to another runtime.
- A guest cannot choose its pack set, policy context or principal.
- A guest cannot reach an MCP server the owner did not clear for cages.
- A guest never receives MCP upstream secrets.
- If rv is unreachable, the guest client denies.

Not guaranteed: that the guest agent calls its hook at all. Section 7 describes the floor.

## 4. Options

| | (a) Hook client over a relayed socket | (b) Admission broker over vsock | (c) Both | (d) rv inside the guest |
| --- | --- | --- | --- | --- |
| Works with stock agents | yes, through their own PreToolUse hook | no: only RV-aware workloads speak the admission frames (`Sources/RVDomain/RuntimeAdmissionCodec.swift:3-7`) | (a)'s coverage | yes |
| Where the command runs | in the guest, by the agent | admitted shell runs host-side under Seatbelt (`Sources/RVIsolation/RuntimeAdmission.swift:44-49`), which defeats the VM, so it needs a new guest executor | | in the guest |
| Policy state lives | on the host | on the host | on the host | in a root-writable guest: needs config copied in, and is tamperable |
| Protocol fit | new, small | one ordered pipe pair with a grant frame (`RuntimeAdmission.swift:519-529`) does not map to many guest connections | | full rv |
| Reuse | C hook front door, hook door, host bridge | admission codec | | Linux build |
| Verdict | **do now** | defer: only for admitted HTTP with credential injection, which the secret gateway already covers | (a) now, (b) on demand | reject |

**Recommendation: (a) plus a host-side MCP endpoint on the same authenticated socket.** If an RV-aware workload ever needs admitted actions in the guest, add `POST /v1/admit` to the same endpoint as evaluate-only admission, with the same token as the capability.

## 5. Design

### 5.1 Topology

```text
guest agent ── PreToolUse ──▶ /.rv/rv hook --host claude
                                  │ POST /v1/hook  Authorization: Bearer <token>
guest MCP client ─────────────────┤ POST /mcp      Authorization: Bearer <token>
                                  ▼
                 guest 127.0.0.1:S ─ rv-guest-relay ─ vsock ─ rv-microvm HostRelay
                                  ▼  (unix upstream, not loopback TCP)
        rv-workspace-host: GuestServicesEndpoint (one per runtime, private 0700 dir)
          token → binding → live principal (authority.resolve)
            ├─ /v1/hook ─ XPC host bridge "rv.host-hook-evaluate" ─▶ rvd HookDoor (instance-bound)
            └─ /mcp ───── stdio ─▶ rv-cli mcp serve --cage-runtime <id> ─▶ upstreams (host)
```

### 5.2 The guest client

The guest client is a static Linux build of the C front door's hook branch (`Sources/rv-c/rv.c:198-230`), compiled with `-DRV_GUEST_CLIENT`. `Scripts/build-guest-relay.sh` builds it with zig next to `rv-guest-relay`, and it ships as `/.rv/rv`. It has no Swift and no Foundation, and keeps the constraints in `Sources/rv-c/README.md`.

- It reads `RV_GUEST_SERVICES_URL` (`http://127.0.0.1:<S>`) and `RV_GUEST_SERVICES_TOKEN` from its environment.
- It sends one `POST /v1/hook?host=<HookHost>` with the raw stdin envelope. The input checks are those of the `input` failure class: ≤ 1 MiB, no NUL, valid UTF-8 (`Sources/rv-c/hook_fallback.c:10`).
- It writes the reply's `stdout` and `stderr` and exits with its `exitCode`, so `HookEvaluateReply` (`Sources/RVIPC/IPCHookEvaluate.swift:38-48`) passes through unchanged.
- Its HTTP/1.1 subset is one request per connection, `Content-Length` only, no chunked encoding, no redirects, 10 s total budget.
- Any failure (connect, timeout, non-200, bad JSON, oversized reply) renders the host's deny shape through `rv_hook_fallback_render`. In this build, `RV_HOOK_WHEN_DOWN` is ignored and there is no ask mode, because the guest controls its own environment (see section 12 for the alternative).

Why HTTP, not the rv frame protocol over a socket: the MCP side needs HTTP on the same endpoint anyway, so one authenticated parser host-side serves both. The guest also connects through `rv-guest-relay`'s TCP port because the vminitd sockets need root (`Packages/rv-microvm/Sources/rv-microvm/Runner.swift:122-124`) and agents often run as non-root.

### 5.3 The endpoint

`GuestServicesEndpoint` lives in RVIsolation and is owned by `WorkspaceSessionSupervisor`, one per micro-VM runtime.

- **Listener.** A unix socket in the runtime's private relay directory, mode 0700. No host loopback TCP port, so other local users cannot connect (the shared-loopback residual in `runtime-boundary.md:570-582` does not grow).
- **rv-microvm change.** `RelayPlan.Entry` gains `upstream: .loopback(port) | .unix(path)`, with a new `--relay-unix <guestPort>=<hostPath>` flag. `HostRelay.bridge` dials the path. The guest side is unchanged and uses one of the 8 pairs.
- **Routes.** `POST /v1/hook`, `POST|GET|DELETE /mcp`. Everything else returns 404.
- **Limits.** Header ≤ 16 KiB, body ≤ 1 MiB, at most 16 in-flight requests per runtime (the host relay caps connections at 128, `runtime-boundary.md:1403`), and a 15 s handler deadline.
- **Auth, on every request.** A bearer token, compared in constant time and mapped to a `GuestServiceBinding{runtime, workspace, instance, scopes}`. The endpoint then resolves the live reference exactly as the bridge client does (`WorkspaceHostBridgeClient.swift:121-126`). Any miss returns 401 with an empty body.

### 5.4 Token minting and revocation

- **Mint.** `GuestServiceCredential`, minted the same way as `EgressProxyCredential` (`EgressProxy.swift:51-56`), next to `makeRuntimeEgress` (`WorkspaceSessionSupervisor.swift:1453`). It is a separate token from the egress credential: different audience, and proxy userinfo travels in more places.
- **Delivery.** Through `microVMRuntimeEnvironment` (`MicroVMLaunch.swift:285-335`), as `RV_GUEST_SERVICES_URL` and `RV_GUEST_SERVICES_TOKEN`. It goes into the `rv-microvm` env only, never argv or a file. Both names join the runtime-managed set, so a resource profile cannot override them.
- **Revoke.** The binding is removed and the listener closed on every path that stops the runtime's egress proxy: `noteDeathObserved` and `noteRuntimeEnded` (`WorkspaceSessionSupervisor.swift:2032-2048`), cancel (`:1383`), and spawn failure (`:1724`). Revocation happens before `finishRuntime` returns, so no request is admitted under a dead principal.
- **Lifetime.** Exactly the runtime. No rotation and no reuse across runtimes. A token written into the workspace publishes to the host, but it is dead by then.

### 5.5 An Agent Instance for every micro-VM runtime

`bridge.evaluate` needs `subject.agent` (`WorkspaceHostBridgeClient.swift:122-124`). Phase 1 mints a launch-observed instance for each micro-VM runtime through `announceAgentInstance` (`WorkspaceSessionSupervisor.swift:1757-1786`). It uses a built-in definition, `rv.cage.microvm`, with an empty authority ceiling: no secret selection, no delegation. This narrows authority, so it is consistent with I9.

When identity launches work in the micro-VM, the named definition replaces the built-in one. That needs the scoped operator permit from the owner action spec.

### 5.6 rvd side

A new host-bridge RPC, `rv.host-hook-evaluate`, sits beside `HostBridgeWire.evaluationKey` (`Sources/RVService/XPCWorkspaceHostBridge.swift:16-26`). It carries `HostBridgeHookEvaluation{id, reference, params: HookEvaluateParams}`. rvd resolves the reference before and after, exactly like host-evaluate (`XPCWorkspaceHostBridge.swift:114-125`), then runs `HookDoor` (`Sources/RVService/HookDoor.swift:10-18`) in a new instance-bound mode:

- **Packs.** `EvaluationWorld.walkedPackIDs(home: configHome)`: the user's effective set. The host sends no list.
- **Policy.** The machine policy plus the repo `.rv/policy.toml`, which is mounted read-only in the guest (`runtime-boundary.md:1395`). Safety level, guard mode, script gate and judge come from the host config.
- **cwd.** The envelope's cwd is used only if it resolves inside `policyWorkspace`. The workspace is shared at the same absolute path. Otherwise rvd uses `policyWorkspace`.
- **No owner authority.** No pending rows, no allow-once codes, no grant spends. Deny text says "denied in the cage; change policy on the host".
- **Audit.** Principal = the reference (instance, runtime, workspace), never the hook host name (I15).

Phase 0 fix, separate and small: `ServiceRuntime.evaluateAgent` walks `walkedPackIDs(home:) ∪ request.enabledPacks`, so a host can only add packs. `WorkspaceHostBridgeClient` stops sending `.makeDayOne`. This alone turns on the user's packs for Seatbelt identity runtimes. An uncommitted working-tree change already does the rvd half (`ServiceRuntime.ownerScoped`, with `Tests/RVServiceTests/OwnerScopedPacksTests.swift`). It applies the same rule to every door. Land it as P0, then remove `.makeDayOne` from the bridge client.

### 5.7 Installing the hook in the guest

Each agent needs an adapter, selected with `rv workspace run --microvm IMAGE --agent-hooks claude -- claude`. Phase 1 ships Claude Code: rv adds `--settings /.rv/hooks/claude.json` (a PreToolUse matcher for all tools, command `/.rv/rv hook --host claude`). The file lives in the read-only tools mount and holds no secret. Codex (`-c` overrides) and OpenCode come in Phase 3. Agents without an adapter get the floor (section 7).

`rv workspace status` reports, per runtime, `cage policy: hook (claude), N evaluations` or `floor only (no hook call seen)`.

### 5.8 MCP inside the cage

- **Gateway.** On the first `initialize`, the endpoint spawns `rv-cli mcp serve --cage-runtime <runtime-uuid>` as a stdio child of the workspace host, on the host. The child exits when the runtime ends, or on `DELETE /mcp`.
- **Transport.** The endpoint implements the server side of streamable HTTP. A `POST /mcp` with one JSON-RPC message is written to the gateway's stdin. The matching response comes back as `application/json`, or as `text/event-stream` when notifications come before it. `GET /mcp` opens the server-to-client SSE stream. The endpoint mints one `Mcp-Session-Id` per runtime. Batches are refused.
- **`--cage-runtime` mode in the gateway:**
  1. Only servers marked `"cage": true` in `mcp.json` are listed. The default is none.
  2. Elicitation approvals are off. The guest agent is the MCP client and could accept its own prompt (`Sources/RVMCP/MCPGatewayCore.swift:21-27, :132-148`). An `ask` waits for host-side `rv mcp approve` (with `UserPresence`) or, later, the owner action route.
  3. `MCPCallRecord` gains the calling principal (instance, runtime), per identity spec §19.
  4. Upstream secrets are released host-side through `SecretRelease` (stdio server and header targets, `CONTEXT.md`) and never cross into the guest.
- **Which servers are safe for cages.** Remote HTTP upstreams run nothing on the host. Local stdio servers run on the host, and `MCPSandbox` is allow-default for reads (`Sources/RVMCP/MCPSandbox.swift:11-14`), so a filesystem-style server would hand the guest host reads. `rv mcp trust` refuses `"cage": true` on a local server without `sandbox`, and warns when the sandbox allows reads outside the workspace.
- **Guest config.** The adapter writes an MCP entry with URL `${RV_GUEST_SERVICES_URL}/mcp` and header `Authorization: Bearer ${RV_GUEST_SERVICES_TOKEN}`, using the agent's environment expansion. The file in `/.rv` stays secret-free.
- **Bypass check.** If a cage server's remote host is also on the runtime's egress allowlist, the guest can reach it directly. `rv workspace status` flags that.

## 6. Fail-closed behaviour

| Event | Hook client | MCP |
| --- | --- | --- |
| `rv-microvm` or the relay dies | the VM dies with it (`runtime-boundary.md:1404`) | same |
| Endpoint closed (runtime ended) | connect fails, so deny | connection error, so the tool call fails |
| Unknown, revoked or other-runtime token | 401, so deny | 401 |
| Instance no longer live | 401, so deny | 401, gateway child stopped |
| rvd down or idle-exited | the endpoint reconnects the bridge once, then 503, so deny ("rv is restarting; retry") | unaffected (the gateway is a host child) |
| Bridge exceeds 11 s (as in `HostAdmission.swift:62-66`) | 504, so deny | n/a |
| Gateway child crashes | n/a | JSON-RPC error, no automatic restart within the session |
| Oversized or malformed request | 413/400, so deny | 413/400 |

No path falls back to a local or day-one evaluation once a runtime is instance-bound. This matches the rule in `HostAdmission.swift:49-51`.

## 7. The generic floor (agents without hooks)

Without a hook, nothing evaluates guest commands. What still holds:

- no guest NIC;
- egress only through the credentialed proxy and its policy;
- secrets only as gateway placeholders or staged entries;
- read-only control paths;
- publish only on close (`runtime-boundary.md:1394-1402`).

What is lost: pack verdicts on commands that use staged credentials.

Options, cheapest first:

1. **Report it.** `rv workspace status` shows "floor only". Always on.
2. **Opt-in shell wrapper.** `--guest-shell` sets `SHELL=/.rv/bin/rv-sh`, which evaluates `-c` strings through `/v1/hook` (as host `generic`) before exec. It covers agents that shell out through `$SHELL`. It is trivially bypassed by calling `/bin/sh` directly, and is labelled best effort.
3. **Exec mediation in the guest kernel** (an LSM or BPF hook on `execve` arguments). Out of scope. It needs investigation against the pinned Kata kernel config, and the guest lacks `CAP_SYS_ADMIN`, which helps.

## 8. Wire and config changes

- `Sources/RVService/XPCWorkspaceHostBridge.swift`: the `HostBridgeHookEvaluation` DTO and the `rv.host-hook-evaluate` key. Registration advertises `guestServicesV1`. A host refuses `--agent-hooks` against an rvd that lacks it.
- `Sources/RVIsolation/WorkspaceControlProtocol.swift`: launch options `agentHooks: HookHost?` and `cageMCP: Bool`, plus a feature flag `microVMGuestServicesV1` next to `microVMLaunchV1` (`:104`). An old host gives `incompatibleProtocol`, as `runtime-boundary.md:1412` describes.
- `Packages/rv-microvm`: `RelayPlan.Entry.upstream` and `--relay-unix`.
- Guest env: `RV_GUEST_SERVICES_URL` and `RV_GUEST_SERVICES_TOKEN`.
- `mcp.json`: a per-server `"cage": true` flag, covered by the existing integrity check.
- RVIPC: no generic IPC change. Guest traffic never touches the rvd socket.

## 9. Tests

Unit tests (all run in the normal suite):

- `Tests/RVServiceTests/AgentDoorPackSetTests.swift` (Phase 0): with `cloud.aws` enabled in a temp home, `evaluateAgent` denies `aws s3 rm s3://b --recursive`. A host list can add packs but never remove effective ones.
- `Tests/RVIsolationTests/GuestServiceCredentialTests.swift`: mint uniqueness; an unknown token, a finished runtime's token, and a sibling runtime's token are all refused; revocation on each of the four teardown paths.
- `Tests/RVIsolationTests/GuestServicesEndpointTests.swift`: header, body and concurrency limits; 404 routes; 401 without a body; bridge timeout gives 504; rvd down gives 503 after one reconnect.
- `Tests/RVServiceTests/HostHookEvaluateBridgeTests.swift`: a wrong or stale reference is refused before and after evaluation; no pending row, no code and no grant spend; cwd outside the workspace is replaced; audit carries the principal.
- `Packages/rv-microvm` tests: unix upstream relay, the plan with mixed upstreams, socket path limits.
- `Sources/rv-c/tests/run.sh` guest build: unreachable, 401, timeout and garbage reply each give the host deny shape for every `HookHost`; `RV_HOOK_WHEN_DOWN=ask` is ignored.
- `Tests/RVMCPTests/CageGatewayTests.swift`: `initialize`, `tools/list`, and `tools/call` allow, deny and ask; `cage:false` servers hidden; elicitation capability stripped; session ID and `DELETE`; secrets absent from every byte sent to the client.

End to end (`Tests/RVIsolationTests/MicroVMWorkspaceEndToEndTests.swift`, `RV_MICROVM_E2E=1`, driven by `Scripts/microvm-proof.sh`), new cases:

- `/.rv/rv hook --host claude` with a `git reset --hard` envelope returns Claude's deny JSON;
- enabling `cloud.aws` on the host makes the guest hook deny `aws s3 rm --recursive`;
- killing the endpoint mid-run gives deny, not ask;
- a token captured in runtime 1 is refused by runtime 2's endpoint and after runtime 1 ends;
- `tools/list` through the guest URL reaches a stub remote upstream;
- the stub's secret value never appears in the guest environment or in the workspace after publish.

Runner: hosted runners lack nested virtualization (`runtime-boundary.md:1439`), and the existing `macos-microvm` job runs only unit suites on `macos-26` (`.github/workflows/pr.yml:550-553`). Add a `macos-microvm-e2e` job on a self-hosted Apple-silicon macOS 26 runner (labels `[self-hosted, macOS, ARM64, microvm]`, 30 min timeout). Constraints:

- It never runs for fork PRs (`github.event.pull_request.head.repo.full_name == github.repository`), and it needs the maintainer label `run-microvm-e2e`.
- It uses no repository secrets. The upstream is a local stub.
- Each job wipes `~/.config/rv` and the image cache, or the runner is a fresh VM per job.
- It runs on every merge to `main` and nightly, so a regression shows within a day even without the label.

## 10. Phased plan

| Phase | Ships | Depends on |
| --- | --- | --- |
| P0 | Agent door uses the effective pack set (in flight: `ownerScoped`); drop `.makeDayOne` in the bridge client; tests | nothing |
| P1 | Built-in `rv.cage.microvm` instance; `GuestServiceCredential`; unix relay upstream; endpoint with `/v1/hook`; `rv.host-hook-evaluate`; guest client; Claude Code adapter; status line; E2E job | P0 |
| P2 | `/mcp` endpoint; `rv mcp serve --cage-runtime`; `"cage": true`; adapter MCP entry; bypass check | P1 |
| P3 | Codex and OpenCode adapters; opt-in `--guest-shell`; `--macvm` support (Darwin build of the client) | P1 |
| P4 | ASK in the cage through the Step 6 action approval (`WorkspaceHostBridgeClient.swift:150-175`); allow-once and MCP ask through the owner action route; optional `/v1/admit` | owner action route |

## 11. Residual risks after P2

- **Any guest process can use the token.** This is by design: they all share one Agent Instance (identity spec §17). A guest helper can therefore ask for evaluations or MCP calls in the agent's name, and nothing more.
- **The `host=` query value is guest-chosen.** It only selects envelope parsing and reply rendering. Instance-bound evaluation keys policy on the principal, never on the hook host (I11). A wrong value yields a parse failure, and so a deny.
- **Host-side MCP widens what the guest can reach.** Each cage server is host code the guest can drive. The `"cage": true` gate plus remote-only (decision 5) keep that set small and explicit.
- **Latency.** Every hook call crosses vsock, the host bridge and possibly the judge. `JudgeOffload` already keeps the judge off the actor (`ServiceRuntime.swift:514-517`). Budget: p95 under 300 ms without the judge. The E2E suite records it.
- **rvd is a single point of failure for cage hooks.** That is acceptable because the failure is a deny, never an allow.

## 12. Decisions for the owner

1. **Default when rv is unreachable from the guest.** Deny always, or honour an `ask` mode set in host config (never guest env)? *Recommendation:* deny always in P1. The guest controls its own agent UI, and an unreachable endpoint means the runtime is ending or rvd is restarting.
2. **One token or two.** Should hooks and MCP share one per-runtime token with scopes, or use separate tokens? *Recommendation:* one token with a scope set. Both have the same principal and lifetime, and a second token adds no isolation inside one guest.
3. **Agent Instance for legacy micro-VM launches.** Mint a built-in zero-authority instance now, or wait for identity launches in the VM? *Recommendation:* mint now. Waiting blocks P1 on the owner action route.
4. **Host transport for the relay.** Unix upstream (needs an `rv-microvm` change), or host loopback TCP plus token (no `rv-microvm` change)? *Recommendation:* unix upstream. It keeps other local users off the endpoint, and the change is about 30 lines in `HostRelay`.
5. **Local stdio MCP servers in cages.** Allow them with `sandbox` set, or remote servers only? *Recommendation:* remote only in P2. Add sandboxed local servers once the sandbox can deny reads outside a declared root.
6. **Elicitation in cage sessions.** Turn it off entirely, or keep it for `ask` calls rated low risk? *Recommendation:* off. A guest agent answering its own prompt is self-approval.
7. **The Phase 0 fix as a standalone PR.** It changes verdicts in existing Seatbelt identity runtimes, which become stricter. Ship it now with a release note? *Recommendation:* yes. Day-one-only evaluation is a silent gap, not a feature.
8. **Self-hosted runner ownership.** Who hosts and patches the Apple-silicon runner, and is a nightly plus label-gated run enough? *Recommendation:* a dedicated Mac mini with one ephemeral macOS VM per job, nightly and on merge, label-gated on PRs.
