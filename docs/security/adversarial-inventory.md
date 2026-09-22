# Runtime adversarial test inventory

Last updated: 2026-09-21. **The release gate is NOT SATISFIED.** All credential paths and signal targets below are disposable, harness-owned fixtures; no real secret contents are collected.

`DENIED` means the named observable effect was blocked in the tested scope. `GAP` means an effect demonstrated missing authority control. `NOT TESTED` is not a pass. A passing `knownGap` test intentionally proves a release blocker. macOS results do not imply Linux results.

Sources: **RA** = [RuntimeAdversarialTests.swift](../../Tests/RVIsolationTests/RuntimeAdversarialTests.swift); **LB** = [LaunchBoundaryRegressionTests.swift](../../Tests/RVIsolationTests/LaunchBoundaryRegressionTests.swift); **EL** = [ExecutorLifecycleRegressionTests.swift](../../Tests/RVIsolationTests/ExecutorLifecycleRegressionTests.swift); **CLI** = [runtime-cli-proof.py](../../Scripts/runtime-cli-proof.py); **LINUX** = [isolation-linux-adversarial.py](../../Scripts/isolation-linux-adversarial.py). Retained [CLI results](evidence/cli-proof.jsonl) report 9 PASS / 10 GAP / 5 NOT-TESTED; [Linux results](evidence/linux-results.json) report 6 PASS / 3 GAP. Both harnesses exit 2. Final run artifacts and command outcomes are indexed in [runtime-acceptance.md](runtime-acceptance.md).

## Process creation and executable indirection

| Technique | Observable assertion / result | Test reference |
|---|---|---|
| `/bin/sh`, `/bin/bash`, `/bin/zsh` | Inside marker created, outside marker absent: DENIED outside write on macOS. | RA `descendantsCannotWriteOutsideWorkspace` |
| `/usr/bin/env` → shell | Same DENIED outside write. | RA `descendantsCannotWriteOutsideWorkspace(.env)` |
| `xargs` → shell | Inside and outside markers stay absent. The contained profile denies `posix_spawn`, which is how `xargs` starts its utility, so the payload does not run. | RA `.xargs` |
| Python/Ruby/Node → shell | `/usr/bin/ruby` ran and outside write was DENIED. `/usr/bin/python3` is the Xcode stub and is NOT TESTED. Node outside `/bin` or `/usr/bin` is NOT TESTED. A missing or out-of-baseline runtime is not coverage. | RA `descendantsCannotWriteOutsideWorkspace` |
| Four nested shells | Inside marker created; outside marker absent: DENIED. | RA `shellIndirectionCannotRemoveWriteFence("nested")` |
| `exec /bin/sh` | Write fence retained: DENIED. | RA `"exec"` |
| Background child with parent waiting | Write fence retained: DENIED. | RA `"background-wait"` |
| Background child after parent exits | After RV returns, the child is dead and a delayed workspace write does not appear. | RA `backgroundChildCannotRetainWorkspaceAuthorityAfterReturn` |
| Nested shell background child | Same: no delayed workspace write after return. | RA `nestedShellBackgroundChildCannotRetainWorkspaceAuthorityAfterReturn` |
| `setsid()` and double-fork | The descendant stays in RV's process group (`setsid` is denied) and is dead before return. A delayed marker does not appear. | RA `setsidProbeCannotRetainWorkspaceAuthorityAfterReturn`, `doubleForkProbeCannotRetainWorkspaceAuthorityAfterReturn` |
| `posix_spawn` + `POSIX_SPAWN_SETSID` | The spawn syscall is denied. The detached child is not created, and the marker does not appear. | RA `posixSpawnSetsidProbeCannotRetainWorkspaceAuthorityAfterReturn` |
| Supervisor SIGKILL | Owned RV supervisor exits -9; cleanup runs only on RV's return path, so a child can still write inside the workspace afterward: GAP. | CLI `supervisor-SIGKILL-cleanup` |
| launchctl service submission | Exit 1 and no outside marker; cause inconclusive, NOT TESTED as a kernel denial guarantee. | CLI `launchctl-service-write-escape` |
| `#!/usr/bin/env sh` and `#!/bin/sh` scripts | Payload runs with inherited outside-write denial. | RA `"env-shebang"`, `"path-replacement"`, `"executable-replacement"` |
| `$PATH` manipulation inside agent | Workspace replacement tool executes; outside write DENIED. | RA `"path-replacement"` |
| Executable replaced inside workspace | Replacement executes; outside write DENIED. This is not executable integrity proof. | RA `"executable-replacement"` |
| Recursive `rv opencode` / another RV process | Nested RV payload executes; outside marker absent: DENIED on macOS. | CLI `recursive-rv-write-fence` |
| Developer tools / scripting runtimes | Python/Ruby/Node covered above; LLDB, compiler toolchains, AppleScript/JXA and other developer-tool escape surfaces NOT TESTED. | RA / omission |

## Filesystem, secrets and launch resources

| Technique | Observable assertion / result | Test reference |
|---|---|---|
| Absolute outside path | Outside touch/write DENIED; positive workspace write control succeeds. | SeatbeltContainmentTests, HostLaunchTests, CLI `cli-write-fence-control` |
| `../`, `../../sibling`, `./nested/../../` | Inside marker proves payload ran; all three outside targets absent: DENIED. | RA `relativeTraversalCannotWriteOutsideWorkspace` |
| Preexisting and newly created symlink chains | Outside write through a chain DENIED. `cp` of a workspace symlink to a sibling file DENIED on macOS. | RA `symlinkChainsCannotWriteOutsideWorkspace`; `SeatbeltCapabilityTests.containedProcessCannotReadSiblingFile` |
| Rename workspace file outside / outside file inside | Operation fails; original files unchanged: DENIED. | RA `renameCannotMoveAcrossWriteBoundary` |
| Agent-created hardlink to outside source | Operation fails and source unchanged: DENIED on macOS. | RA `agentCannotCreateAnOutsideHardlinkOrMutateOutsideSource` |
| Host-created hardlink alias inside workspace | A link that already exists makes launch return `workspaceContainsInodeAlias` and the command does not run. A link planted by another same-user process after the contained process is running fails with `EXDEV`; the outside file stays unchanged. | RA `preexistingHardlinkAliasRefusesLaunchBeforeExecution`, `hardlinkCreatedAfterPreflightCannotMutateOutsideInode` |
| Workspace symlink retargeted between prepare and run | Typed failure and neither workspace marker appears: DENIED by revalidation. Residual races remain. | LB `preparedWorkspaceRetargetDoesNotChangeGrantOrWorkingDirectory` |
| Linux canonical path replaced by symlink | Exit 125 and no marker: DENIED in C unit with Landlock stubbed. | LINUX `C-unit-canonical-retarget-rejected` |
| Path containing quote, backslash, profile injection text, tab, carriage return | Inside write succeeds; outside write DENIED by actual Seatbelt. | LB `seatbeltPathEncodingCannotBroadenWriteScope` |
| NUL in executable/argument | Construction fails before launch. | LB `embeddedNULCannotChangeExecutedArgv` |
| Root, missing/non-directory workspace, relative/missing executable | Covered inputs fail with no marker. | IsolationApplyTests, LandlockApplyTests, OpenCodeCommandTests, CLI startup probes |
| Fake SSH key/config, AWS, GCloud, `.env`, Git credentials, shell histories, `.zshrc`, browser cookie DB, keychain DB, RV policy/binary | macOS `cat` into the workspace fails and the copy does not contain the synthetic value. Writes stay denied. The older CLI JSONL that recorded these reads is the previous allow-default profile and was not re-run. Reading a keychain fixture does not prove real keychain decryption. | RA `knownGapSyntheticCredentialsAreReadableButCannotBeOverwritten` |
| Git hooks / RV config / shell startup files inside workspace | Writable: GAP in protected control-plane/content consumption boundary. | RA `knownGapWorkspaceGitHooksAndRVConfigurationRemainWritable` |
| Descriptor above stdio opened before contained launch | Child gets `EBADF` and cannot write the outside file, socketpair, or pipe. The outside file stays unchanged. macOS contained spawn only. | DescriptorHygiene `ambientOutsideFileDescriptorIsNotWritable`, `ambientSocketpairIsNotUsable`, `ambientPipeIsNotUsable`, `containedProcessListsOnlyGrantedDescriptors` |
| Linux preopened descriptor above stdio | Production Linux launch does not exec. A stubbed C unit closes descriptors above stdio with `close_range`; that is not a contained-runtime guarantee. | Linux contained prepare returns `containedGuaranteesUnsupported`; LINUX `C-unit-inherited-fd-closed` |
| Preopened stdin/stdout/stderr | Discard mode is `/dev/null` for all three. Inherit mode is the parent's descriptors and accepts a write. Inherited stdio remains a capability to that resource. | DescriptorHygiene `discardedStandardIOIsNullDevice`, `inheritedStandardIOMatchesParent` |
| Loader/interpreter/secret environment | Production contained spawn emitted no synthetic ambient/loader variables; values not logged. | LB `containedEnvironmentContainsOnlyDeliberateValues`; CLI `synthetic-secret-and-loader-environment` |
| Direct Linux helper with loader injection | Constructor executed before rejected Landlock setup: GAP for direct helper. Production Swift sanitizer is a separate layer: actual Linux Swift startup confirms the constructor marker stays absent (`linux-swift.log`); supported-kernel execution unproven. | LINUX `direct-helper-loader-environment` |
| `/proc`, `/sys`, devices, mounts, ptrace, setuid/capability elevation | NOT TESTED under actual RV Linux enforcement; source has no namespace/seccomp boundary. | LINUX unavailable-kernel evidence |

## Network and host processes

| Technique | Observable assertion / result | Test reference |
|---|---|---|
| Loopback IPv4 TCP / UDP | Native client: unsandboxed payload arrives; sandboxed client and `/bin/sh` child get `errno=1` and the listener stays empty. DENIED on macOS. | `SeatbeltCapabilityTests.containedProcessCannotConnectOrResolve` |
| Loopback IPv6 TCP | Same native client: DENIED on macOS (`errno=1`). UDP IPv6 was not given its own case. | Same test |
| Unix stream socket | Same native client: DENIED on macOS. Datagram Unix was not tested. | Same test |
| DNS via `getaddrinfo("example.com")` | Unsandboxed prints `dns ok`. Sandboxed prints `dns rc=` and not `dns ok`. Raw IP connect is still `errno=1`. | Same test |
| Public IP / LAN / system DNS resolver / curl or other network clients | NOT TESTED. Existing direct socket connections already refute default-deny network; absence of those probes remains explicit. | CLI omissions / inventory |
| Host/domain allowlist bypass using raw IP | NOT APPLICABLE to current API: no host/domain policy is supported. Future enforcement remains unproven. | `NetworkContainment.unrestricted` |
| Signal harness-owned unrelated process | `kill -TERM` returns nonzero and the `sleep` is still running: DENIED on macOS. | RA `knownGapCanSignalSyntheticUnrelatedProcess` |
| Signal/alter RV supervisor itself | NOT TESTED as a separate victim. The same signal rule is what denied the harness sleep. | RA signal test is not a supervisor probe |
| Inspect unrelated processes / attach debugger / privileged operations | NOT TESTED sufficiently; ordinary OS security is not an RV policy boundary. | Boundary review |

## State, failure and concurrency

| Technique | Observable assertion / result | Test reference |
|---|---|---|
| Two simultaneous workspaces attack each other's write tree | Own markers exist; cross-write markers absent: DENIED on macOS. Reads and identities are not isolated. | RA `concurrentWorkspacesCannotAcquireEachOthersWriteAuthority` |
| Two concurrent dispatches of one authorization | One execution, one `alreadyExecuted`, exactly one marker append. | EL `concurrentDispatch_sameAuthorizationExecutesOnlyOnce` |
| Retry after failed isolation apply | Authorization reserved; retry rejected and no marker appears. | EL `failedApply_consumesAuthorizationBeforeRetry` |
| Child exits reserved helper status after effects | Same authorization cannot replay effects. Linux interpretation branch needs actual Linux run. | EL `reservedChildExit_cannotReplayCompletedSideEffect` |
| Cancel before dispatch | No marker; later authorized dispatch succeeds once. | EL `cancelledBeforeDispatch_doesNotExecuteOrConsumeAuthorization` |
| Cancel after dispatch / runtime crash | NOT TESTED as cleanup guarantees and not implemented as supervised-tree lifecycle. Supervisor SIGKILL gap is tested above. | Boundary review |
| Malformed Seatbelt profile | No marker. The result is `seatbeltNotEstablished`, not `EstablishedIsolation`. | LB `invalidSeatbeltProfileDoesNotExecuteInnerCommand` |
| Linux unavailable kernel | Real helper exits 125; marker absent: fail closed. | LINUX `actual-unsupported-kernel-fails-closed` |
| Inject descriptor-cleanup or workspace-open failure | Exit 125; marker absent, with Landlock stubbed: fail-closed C setup evidence only. | LINUX `C-unit-descriptor-cleanup-error-fails-closed`, `C-unit-path-open-error-fails-closed` |
| Policy parser / logging / child-tracker failure | NOT TESTED: launcher has no runtime policy parser, mandatory audit sink or child tracker to inject. These are missing required boundaries. | CLI policy-parser omission / boundary review |
| Malformed agent executable/workspace configuration | Validated CLI fields rejected without command effect; no general agent-configuration schema exists. | OpenCodeCommandTests / CLI startup probes |
| C frontend PATH / forged argv0 / malicious HOME | Correct sibling CLI selected from actual executable path; HOME fallback removed. Darwin/Linux C tests pass and staged PATH write control succeeds. | `Sources/rv-c/tests/run.sh`; CLI `cli-path-write-fence-control` |
| Linux Swift helper with forged relative argv0 | Correct helper located via `/proc/self/exe`; sanitized constructor absent and unsupported-kernel marker absent. | Retained `evidence/linux-swift.txt` |
| Impersonation, stale session grants, grant revocation | NOT TESTED: authenticated runtime identity and capability lifetime model absent. | Boundary review |

No real-Linux positive enforcement result is claimed. The Linux container used kernel `6.10.14-linuxkit`, which reports `ENOSYS` for Landlock and `CONFIG_SECURITY_LANDLOCK` unset. Its Docker confinement cannot substitute for RV enforcement evidence.
