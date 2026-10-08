# Fresh Adversarial Review — Phase 2A.3-PR2

Provenance: branch `phase-2Identity`, commit `e2908335`, reviewed 2026-10-01.
Method: 10 fresh-context reviewers, read-only inspection (383 tool calls);
parent spot-verified the deny posture and single-choke claims before delivery.
Tree untouched by the review itself.

## Ground truth

PR2 core per `git e2908335 --stat`: NEW `PreparedWorkspaceLaunch.swift` (417), `WorkspaceSessionSupervisor.swift` (+422), auth 1-line, +`PreparedWorkspaceLaunchTests` (1172). Commit msg: "Dispatch stays unreachable; identity launch remains denied... No production authorization enabled."

Sole production chain: `Sources/RVIsolation/WorkspaceHostServer.swift:486` `operation()` routes `.launchAgentRuntime/.launchCustomRuntime` to `launchIdentity`; `:738` calls `AgentLaunchSelection.resolveNamed/resolveCustom` (defs `RVPolicy/AgentLaunchSelection.swift:34,67`); `:757` ONLY production `supervisor.launchAgent` caller (rg: all others in `Tests/`); `WorkspaceSessionSupervisor.swift:430` calls `prepareIdentityLaunch` (ONLY production prepare site); `:567` constructs `PreparedWorkspaceLaunch` (docstring: never spawns, mints nothing); `:437` feeds prepared into `dispatchPreparedLaunch` (ONLY production dispatch site); `:628` def with store-usability + credential-free + `retainedIntentMatches` gates; `:656` consumes retained state via `establishRuntime` (no re-resolution); `:845` calls private `spawn`, `:1028` revalidates `isUsable(preparedID)` at commit; `:1053` calls `spawnSeatbeltProcess` with retained `preparedEnvironment`; `SessionSupervisor.swift:604` reaches `posix_spawn` (via `:301` wrapper + `:380` deny file-link guard).

Auth: `WorkspaceOperationAuthorization.swift:12` `launchRuntime/launchAgentRuntime/launchCustomRuntime/terminal` return false, peer ignored; `git show e2908335` auth diff ADDED `.launchAgentRuntime/.launchCustomRuntime` to unconditional-deny group; `WorkspaceHostServer.swift:455` single choke `guard permits() else unauthorizedClient` precedes ALL launch handlers; `WorkspacePeerAuthenticator.swift:4` roles cli/service/workspaceHost, deny branch ignores role; `Tests/.../WorkspaceLaunchIntentCouplingTests.swift:82` asserts `permits()==false` for 4 ops x nil/cli/service/workspaceHost; `WorkspaceHostClient.swift:347` launch calls go over transact socket, no direct supervisor access; `RVCLI/Commands/WorkspaceCommand.swift:416` CLI funnels to client calls, XPC bridge handles only registration/evaluation.

## Prepare→execute invariant (PASS)

Sole production path `launchAgent` chains prepare->dispatch (`WorkspaceSessionSupervisor.swift:423-442,619-623`); no dispatch-by-ID or wire decode of prepared state. Dispatch takes caller-passed struct; store consulted only via `isUsable(ID)`, never returns state (`:628-640` + `PreparedWorkspaceLaunch.swift:284-293`). `retainedIntentMatches` re-verifies revision/profile==manifest, rebuilds intent from retained argv, requires digest equality (`:696-735`). Spawn-commit revalidates `isUsable(preparedID)` (`:1028`). `verifyPreparedSelection` re-checks revision (`PreparedWorkspaceLaunch.swift:358-361`). Tests: `dispatchRejectsDivergentRetainedSelection` incl. swapped-manifest evil-profile twin (`PreparedWorkspaceLaunchTests.swift:949-1016`); `configChangeAffectsOnlyNewPreparations` (`:685-714`).

## Definition/profile integrity (PASS)

`WorkspaceHostProcess.swift:31-45` policy+definitions loaded once into immutable lets, no reload. Server holds `private let agentDefinitions` (`WorkspaceHostServer.swift:121,738-739`), named selection from snapshot only. `resolveNamed` rejects unless `revision==resolve(definition)`, single link target + profile frozen (`AgentLaunchSelection.swift:42,58-64`). `verifyPreparedSelection` re-checks (`PreparedWorkspaceLaunch.swift:358-361`); `committedEffectiveProfile` rejects mismatch (`:369-385`); `makeNamed` re-verifies + binds id+revision+exe+argv in digest (`WorkspaceLaunchIntent.swift:269-280`). Dispatch re-checks `resources?.profile==effectiveProfile` + digest (`WorkspaceSessionSupervisor.swift:705`). Announce uses retained definition only (`:1120-1129`). Evil-profile twin rejected, honest twin dispatches (`Tests:949-1016`).

## Custom isolation (PASS, PR2 scope)

`resolveCustom` builds AdHoc snapshot from digest only; hardcodes profile nil, hook/agentTag nil, ceiling `.none` (`AgentLaunchSelection.swift:67`). Verify rebuilds from definition's own digest, demands full equality (`PreparedWorkspaceLaunch.swift:348`); custom requires `resourceProfile==nil` (`:379`). `makeCustom` binds only exe+digest+cwd+argv+io (`WorkspaceLaunchIntent.swift:306`). Wire hook/resourceProfileID rejected; custom takes only exe+digest+args+io (`WorkspaceHostServer.swift:728`). `permits()` false for all peers (`WorkspaceOperationAuthorization.swift:12`). Expected digest is intent-only, never measured (`WorkspaceLaunchIntent.swift:141`, no hash call site); `stage()` only realpaths+isExecutable (`RuntimeResourceManifest.swift:41`). Not exploitable in PR2 (unreachable); measurement is Phase 4 scope.

## Executable intent retention (PASS)

Intent binds id+revision+exe+argv digest (`WorkspaceLaunchIntent.swift:269-280`); dispatch re-derives digest (`WorkspaceSessionSupervisor.swift:696`) but never re-resolves (`:656`). Spawn argv from `request.command` (`SessionSupervisor.swift:542`). Staging symlinks retained-profile links but realpaths live targets; bytes unmeasured — Phase 4 (`RuntimeResourceManifest.swift:41-48`). `ExecutableAssurance` has only unattested/launchObserved; hardcoded `.launchObserved` satisfies any current `requiredAssurance` (`AgentDefinition.swift:37-43`) — LOW, deferred (see Findings).

## argv integrity (PASS)

Order/dupes/empty/unicode retained identically in command, intent, launchRequest (`PreparedWorkspaceLaunchTests.swift:175-190`). Bounded (<=64 args, <=8192B, NUL-free); canonical bytes preserve order/dupes/empties/unicode (`WorkspaceLaunchIntent.swift:344-350,376-403`). Spawn uses retained `request.command` (`SessionSupervisor.swift:542`).

## cwd integrity (PASS for PR2, hardening deferred)

Prepare resolves cwd via live `existingResolvedWorkspacePath(policyWorkspace)` (`WorkspaceSessionSupervisor.swift:496`), requires `compiled.containedWorkspacePath==resolved` (`:546`); `/tmp`→`/private/tmp` canonicalization consistent (`SeatbeltProfile.swift:845`). Dispatch compares retained strings only (`WorkspaceSessionSupervisor.swift:842`); spawn chdirs by retained string via `posix_spawn_file_actions_addchdir` (`SessionSupervisor.swift:489`); `remainsEstablished` checks held-fd device only (`WorkspaceInodeBoundary.swift:167`); `mountedIdentityMatches` exists but only `detachOwnedMount` calls it (`:323`); dispatch never re-checks hook/stagingAgent/env (`WorkspaceSessionSupervisor.swift:696`). Not reachable in PR2: synchronous prepare->dispatch sole path, no delayed dispatch-by-ID, wire dispatch denied. Defer live revalidation to later phase (see Findings).

## Environment integrity (PASS)

Prepare freezes live host dict + `containedRuntimeEnvironment(keychain:[], productive)` (`WorkspaceSessionSupervisor.swift:552`). `preparedEnvironment!=nil` bypasses recomputation entirely, frozen bytes verbatim (`SessionSupervisor.swift:577`; also retained `?? recompute` `:577`). Profile hostVariable/literal resolved from frozen dict; present-set blocks override of runtime names (`SessionSupervisor.swift:869`). `privateHome/bin` symlinks staged live at spawn; PATH string frozen but dir contents live (`RuntimeResourceManifest.swift:41`) — path fixed, acceptable PR2. Credential-free gate at dispatch (`WorkspaceSessionSupervisor.swift:628`).

## Resource/manifest integrity (PASS)

Dispatch reuses `var request = prepared.launchRequest` verbatim; only `withSpawnFault` applied, preserves resources/productive (`WorkspaceSessionSupervisor.swift:652`). Sole `RuntimeResourceManifest(` construction inside `prepareSeatbelt` (`IsolationApply.swift:497`); dispatch never calls prepare/compile. Spawn stages retained `request.resources` (`SessionSupervisor.swift:544`), never new manifest. `request.productive ?? resolveProductiveWorkspace` — retained Some on prepared path, fallback only legacy nil (`:563`). Spawn takes seatbeltProfile+containedWorkspacePath from retained request, `profile.source` verbatim to sandbox-exec argv (`WorkspaceSessionSupervisor.swift:995`).

## Preparation side effects (PASS)

Prepare never spawns per docstring (`WorkspaceSessionSupervisor.swift:567`); passes `gitIdentity:{_ in (nil,nil)}` into `prepareSeatbelt`, disabling only git-spawn site (`:539`); sole git spawn at `WorkspaceDeveloperHome.swift:316`. `stage()` only realpaths+isExecutable (`RuntimeResourceManifest.swift:41`).

## PreparedLaunchID authority analysis (PASS — no authority)

ID is liveness-only: dispatch takes struct, store consulted only via `isUsable(ID)` (`WorkspaceSessionSupervisor.swift:628-640` + `PreparedWorkspaceLaunch.swift:284-293`); no dispatch-by-ID (`:423-442,619-623`); spawn-commit `isUsable(preparedID)` revalidation (`:1028`) gates liveness, not data. Caller cannot mint authority by guessing IDs.

## Store lifecycle (PASS)

Immutable snapshot at host start, no reload (`WorkspaceHostProcess.swift:31-45`). Old prepared still dispatches retained `/bin/sleep` after config change (`PreparedWorkspaceLaunchTests.swift:685-714`) — retained-data independence proven. `isUsable` gates at dispatch (`:628`) and spawn commit (`:1028`).

## Concurrency/races (PASS)

Immutable `let` policy/definitions (`:31-45`), `private let` server snapshot (`:121`), value-type `PreparedWorkspaceLaunch` retains selection+command+io+env+productive+request+hook in one struct (`:567-587`), single synchronous prepare->dispatch chain (`:423-442`), no reload path, no shared mutable on dispatch path in evidence. No explicit race test cited; residual risk low given value semantics + unreachable dispatch.

## Secret leakage (PASS)

Credential-free dispatch gate (`:628`); prepare uses `keychain:[]` (`:552`); git identity nil (`:539`); intent binds only exe/digest/cwd/argv/io, no cred/profile/hook/ceiling inputs (`WorkspaceLaunchIntent.swift:306`); custom AdHoc nils hook/tag/ceiling (`AgentLaunchSelection.swift:67`); announce `authority=definition.authorityCeiling` recomputed from retained definition only (`:1120-1129`).

## Dispatch reachability (PASS — denied confirmed)

`permits()==false` for launch ops all peers (`WorkspaceOperationAuthorization.swift:12`); 4 ops x nil/cli/service/workspaceHost asserted (`Tests:82`); deny ignores role (`WorkspacePeerAuthenticator.swift:4`); choke `:455` precedes ALL handlers; PR2 added identity ops to deny group; commit msg confirms; client socket-only (`:347`), CLI funnels to denied ops (`:416`).

## Legacy regressions (PASS)

Retained `Some(productive)` on prepared path; `?? resolveProductiveWorkspace` fallback only for legacy nil requests (`SessionSupervisor.swift:544,563,577`). Additive new files/path; no dispatch-by-ID preserves legacy callers.

## Phase 1/PR1 regression (PASS)

Deny group extended (strictly more restrictive); no production authorization enabled per msg; choke, staging, `posix_spawn` path reused verbatim (`:544,:995,:604`).

## Broad-gate classification

PR2 is NON-PRODUCTION-GATED: unreachable dispatch + unconditional identity-launch deny. Broad gates (content-digest measurement, cwd live revalidation, ExecutableAssurance attestation beyond `.launchObserved`) correctly remain Phase-4 scope; PR2 opens no broad production gate.

## Findings

L1 — Executable bytes unmeasured; `.launchObserved` satisfies any current assurance | LOW | `Sources/RVDomain/AgentDefinition.swift:37-43`, `Sources/RVIsolation/RuntimeResourceManifest.swift:41-48`, `Sources/RVDomain/WorkspaceLaunchIntent.swift:141` | Attack: swap binary bytes under same path after prepare; intent digest (expected-only) would not detect | Repro: per evidence, no hash call site on custom path; `stage()` only realpath+isExecutable | Impact: none in PR2 (dispatch unreachable); real in later reachable phase | Remediation: Phase 4 content hashing + `requiredAssurance` enforcement | PR2-or-later: LATER.

L2 — Dispatch cwd comparison is retained-strings-only; live `mountedIdentityMatches` unused on spawn path | LOW | `Sources/RVIsolation/WorkspaceSessionSupervisor.swift:842`, `Sources/RVIsolation/SessionSupervisor.swift:489`, `Sources/RVIsolation/WorkspaceInodeBoundary.swift:167,323` | Attack: path-swap/rebind between prepare and spawn if delayed dispatch existed | Repro: `:842` zero live realpath; `:489` chdir by retained string; `:167` fd-device-only | Impact: none in PR2 (sync chain, no dispatch-by-ID, wire denied) | Remediation: re-resolve + `mountedIdentityMatches` at dispatch/spawn commit when dispatch becomes reachable | PR2-or-later: LATER.

No CRITICAL/HIGH/MEDIUM findings reproduced; only the two LOW deferred notes above.

## Review Summary

| Severity | Count | Status |
|---|---:|---|
| CRITICAL | 0 | none |
| HIGH | 0 | none |
| MEDIUM | 0 | none |
| LOW | 2 | both deferred, no PR2 impact |

## Final verdict

```text
APPROVE PR2
```
