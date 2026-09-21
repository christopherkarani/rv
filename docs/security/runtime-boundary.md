# RV runtime security boundary

Last updated: 2026-09-21. Audit base: `854e69103333a65e86deacac853f915adc450868`, with the uncommitted hardening pass described in [the acceptance matrix](runtime-acceptance.md). **Release status: NOT SATISFIED.** The implemented containment is a workspace write fence. It is not a default-deny agent capability system.

## Implemented execution paths

```mermaid
flowchart TD
    CLI["C rv → Swift rv-cli: opencode [--executable PATH] [--workspace PATH] [-- ARGUMENTS]"] --> Parse["RV.configuration → OpenCode.run / OpenCodeRun.run"]
    Parse --> Resolve["Absolute executable lookup; WorkingDirectory; IsolatedCommand"]
    Resolve --> Plan["compileIsolationPlan(.contained): workspace read/write, network denied, signals to others denied, descent inherited"]
    Plan --> Launch["launchContainedHost(.opencode): reject other hosts and uncontained plans"]
    Launch --> Apply["IsolationBackends.apply → platform.prepare → spawn"]
    Apply --> Env["Revalidate canonical workspace; replace environment; inherit stdio"]
    Env --> Mac["macOS: /usr/bin/sandbox-exec -p PROFILE EXEC ARGS"]
    Env --> Linux["Linux: sibling rv-isolation-exec --workspace PATH -- EXEC ARGS"]
    Mac --> Seatbelt["Seatbelt: deny default; workspace read/write; no network allow; signal self only"]
    Linux --> Landlock["close_range; no_new_privs; ABI >= 3; write-class Landlock; execve"]
    Seatbelt --> Agent["Untrusted agent executable"]
    Landlock --> Agent
    Agent --> Children["Agent-spawned shells, interpreters and descendants inherit OS fence"]
    Agent --> Wait["RV waits for immediate child; returns exit status"]

    Authorization["Separate API: AgentAuthorization / AllowedAction"] --> Compile["compileExecutable(allowed, plan)"]
    Compile --> Executor["LocalExecutor.run: actor; reserve action fingerprint before dispatch"]
    Executor --> Apply
```

There is **no runtime identity issuance, authenticated identity → policy lookup, or semantic policy → capability compilation stage** on the CLI path. `rv <agent>` currently means the single registered `rv opencode` subcommand. Other agent hosts are not launchable through this door. The selected executable need not be a verified OpenCode binary; `--executable /bin/sh` is deliberately supported for testing. `HookHost.opencode` identifies the launch adapter, not a principal.

`LocalExecutor.perform` is an independent authorized-action API. It is not called for the OpenCode process or its tools. Agent-created descendants do not re-enter `perform`, policy evaluation or approval. Their inherited kernel restrictions are the only RV containment applied to those operations. Hook evaluation/history elsewhere in RV does not establish mediation of this process tree.

The general `IsolationBackends.apply` API still implements explicit observed/mediated execution without a sandbox. `launchContainedHost` and `LocalExecutor.run` reject these modes, and the CLI constructs contained plans. This is a restricted launch door, not proof that every use of RV's library APIs is supervised.

## Components and trust assumptions

| Component | Trust and concrete responsibility |
|---|---|
| RV CLI, `OpenCodeRun`, domain compiler, isolation backend and executor | Trusted code. Validate launch input and request the fence. They have the invoking user's ambient authority. |
| macOS kernel and `/usr/bin/sandbox-exec` | Trusted enforcement/loader path. The kernel enforces the generated write rules on the process and descendants. |
| Linux kernel, helper, dynamic loader and linked libraries | Trusted pre-isolation path. Helper must be an executable regular file named `rv-isolation-exec` outside the workspace. This is a path check, not cryptographic authentication, ownership validation or an inode-pinned launch. |
| Workspace and agent executable/arguments | Untrusted work. The host/operator deliberately selects the write root and executable. Agent-written scripts, replacements, shebangs and descendants are untrusted. |
| Parent directory tree and installed RV/helper | Assumed stable and outside adversary write authority while preparing and launching. The audit has not established protection against a same-user external attacker replacing these resources. |
| Inherited standard handles | Explicitly passed by host launch. They remain capabilities to their underlying resources; RV does not classify, attenuate or audit them. `apply`/`perform` discard all three by default. |
| Host services, Unix sockets, system processes and credentials | Not isolated by the current capability model. OS permissions still apply; RV does not add default-deny access rules for them. |
| Hook request `SessionID` | Optional validated nonempty self-declared string, not an authenticated runtime identity. It must not become a credential/wallet authority without a new binding. |

The C frontend now locates its sibling `rv-cli` from the running executable path (`_NSGetExecutablePath` on Darwin, `/proc/self/exe` on Linux), not caller-controlled argv0 or HOME. Linux Swift helper resolution uses only the `/proc/self/exe` sibling; it has no argv0/bundle fallback on Linux. Legacy lookup is confined to the non-Linux conditional branch. Darwin/Linux C tests and the staged PATH CLI proof validate the corrected dispatch. These checks do not authenticate file ownership/content or eliminate executable replacement races.

An attacker inside the write root may also find host-created hardlinks to resources outside it. This violates the intended file boundary on the tested macOS host: changing the workspace alias changed the outside file. Trusted workspace preparation is not a proven substitute for kernel enforcement and this remains a release blocker.

## RV policy, RV checks and OS enforcement

**RV policy:** `Sources/RVDomain/Isolation.swift` defines closed enums and immutable plans for observed, mediated and contained modes. Contained means `.workspaceScoped(workspace)`, network `.denied`, process `.hostSignalsDenied`, and descent `.inherited`. These are isolation intentions, not authenticated per-agent capabilities. `compileIsolationPlan` is a pure function of its typed input. Backend compilation additionally resolves filesystem paths, so its output depends on the current filesystem. Landlock compilation of that plan fails closed.

**RV launch checks:** `IsolatedCommand` rejects relative/empty executables and embedded NULs in argv. Contained prepare/run checks reject `/`, nonexistent and non-directory workspaces, unsafe paths, and a caller alias retargeted between prepare and spawn. The spawn boundary replaces the environment with `PATH=/usr/bin:/bin`, `LANG=C`, `LC_ALL=C`, `HOME=<workspace>` and `TMPDIR=<workspace>`. Ambient secret values, loader variables, interpreter variables, proxy/socket references and search paths are not forwarded. A shell can add its own bookkeeping variables. This restricts inherited environment authority; it does not hide host files or network services.

**Seatbelt enforcement:** `SeatbeltProfile.swift` generates `(deny default)`. It allows `process-exec`, `process-fork`, `signal` to self, `sysctl-read`, unfiltered `mach-lookup`, `file-read-data` of the root inode, `file-read-metadata` on `/private`, `/tmp`, `/var`, and `/Users`, and file read/map/ioctl on `/usr`, `/bin`, `/System`, `/Library`, `/dev`, plus read/write of the canonical workspace. The granted executable is an extra literal read/map allow, including its realpath. Actual macOS tests deny ordinary outside reads and writes, symlink reads and writes, relative traversal, interpreter and shell wrappers, loopback and public TCP, UDP, IPv6, Unix sockets, and DNS. `kill` of another test-owned process is denied. Quotes and backslashes in profile paths are escaped; NUL, newline, and root paths fail validation. A workspace regular file with link count greater than one refuses launch. That scan is not a kernel inode rule. `mach-lookup` is not a closed IPC policy. Linux does not apply this profile.

**Landlock enforcement:** the C shim handles write-class filesystem bits, including `REFER` and `TRUNCATE`, and requires ABI 3. It sets `no_new_privs`, resolves the canonical workspace with `openat2(RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS)`, then applies `landlock_restrict_self` before `execve`. Helper startup closes descriptors above 2 using `close_range`, failing closed if that fails. No read/execute/network rules, namespaces, seccomp, cgroups or PID controls are installed by RV. Docker's namespaces/seccomp/network restrictions in the audit fixture belong to Docker and are not RV guarantees. Actual Landlock enforcement was **not available** on the tested Linux kernel; only unsupported-kernel fail-closed behavior and separately labeled C setup tests were observed.

The [Linux kernel Landlock API documentation](https://docs.kernel.org/userspace-api/landlock.html) describes inherited restrictions and limitations for descriptors opened before sandboxing. It is platform background, not evidence that RV applied those controls on a supported kernel.

The code does not support host/domain network grants. No hostname allowlist should be inferred from Seatbelt or its current profile. A future domain policy needs an enforcement layer that also handles IP connections, DNS, resolution changes and direct sockets. This audit proves neither that Seatbelt alone can express that future policy safely nor that such a broker exists in RV.

## Failure and lifecycle limits

1. Invalid commands, workspace checks and unavailable backends return typed errors before inner execution; marker tests verify the covered paths. An invalid Seatbelt profile prevents the inner marker from executing.
2. `EstablishedIsolation` is **not a trustworthy startup attestation**. Seatbelt wrapper failure can still return a successful `IsolatedRunResult` containing `.contained` and a nonzero exit. Linux helper exits 125/126 distinguish setup/exec failures only by convention; an inner executable can itself use those codes. No protected startup handshake exists.
3. `LocalExecutor` now records an action fingerprint before a potentially effectful dispatch. An ambiguous failure cannot replay the same authorization in that executor. Pre-dispatch cancellation consumes nothing. Another executor is a separate deduplication scope; there is no global identity/session lease.
4. RV waits only for the immediate process. A real background descendant continued writing inside its grant after its immediate parent returned. A real CLI probe also killed its owned RV supervisor with SIGKILL and observed the child writing afterward. Cancellation after dispatch, supervisor death, revocation and crash cleanup are not implemented as process-tree guarantees.
5. A real isolated shell signaled a harness-owned unrelated process successfully. An agent directly killing the RV supervisor or manipulating it through available IPC is not excluded by current process policy. A launchctl service-submission probe exited 1 without the outside marker; its cause was inconclusive and cannot count as a kernel denial. Debugger attachment, privilege operations and host process inspection have not received sufficient probes.
6. Inherited stdio may reference files, sockets or terminals already opened with authority. The macOS CLI fixture showed a supplied descriptor above 2 did not mutate its outside fixture; it does not certify arbitrary descriptor inheritance or stdio safety. Linux C descriptor tests stub Landlock and do not prove descriptor behavior under an actual restricted kernel.
7. Canonical path revalidation closes a demonstrated alias-retarget window. It does not pin the workspace/executable/helper inode across every subsequent race, prevent same-path directory replacement, or authenticate the helper. The direct dynamic helper can execute an injected loader constructor before `main`; production Swift spawn strips the relevant environment. An actual Linux Swift startup probe confirms the constructor marker stays absent and the unsupported kernel prevents inner execution. Positive enforcement on a supported kernel remains unproven.
8. Workspace files include `.git/hooks`, shell startup files and any RV policy/config/binary placed there. These are writable. RV does not reserve protected control-plane subpaths or prevent an outside same-user controller from consuming those files later.
9. No required structured execution audit sink exists. PID, child-tree identity, effective policy identity, capability set, operation rationale and kernel denies are not recorded by this launch path. A logging failure therefore cannot fail closed at an audit boundary that has not been implemented.

## Remaining work, by release impact

| Priority | Gap | Required next evidence |
|---|---|---|
| Release blocker | Default-allow reads, network, IPC and process interaction | Typed capability compiler and real negative tests for secret reads, IPv4/IPv6/TCP/UDP/DNS/Unix sockets and host processes on both supported OSes. |
| Release blocker | No authenticated runtime identity, identity-bound policy or mandatory execution audit | Two identities with differing authority; impersonation/forged-session rejection; structured X/Y/Z/P/S event plus logging-failure tests. |
| Release blocker | Descendants bypass semantic authorization; no session lifetime ownership | Defined OS-vs-broker boundary, descendant tracking and termination/revocation tests including cancellation and supervisor death. |
| Release blocker | macOS outside-file mutation through preexisting hardlinks; unclassified inherited handles | Kernel-enforced or deliberately reduced filesystem/descriptor design with regression effects, including stdio and inode aliases. |
| Release blocker | Startup establishment inferred from exit status | Protected helper handshake with actual apply failure, exec failure, child exit 125/126 and crash tests. |
| Release blocker | Linux enforcement unproven; no process/network boundary | Actual Landlock ABI >= 3 Linux host and CI/container runs; fail-closed required namespaces/seccomp if those become the selected mechanisms. |
| Important hardening | Filesystem path/executable/helper replacement races and helper provenance | Inode-stable grant/launch design and adversarial race tests; trusted ownership/install validation. |
| Important hardening | TMPDIR/HOME mapped to workspace; broad shared write root | Deliberate temporary-directory permissions and cleanup tests; protected control-plane paths. |
| Important hardening | CLI compatibility under minimal environment and platform packaging | Real OpenCode interactive smoke test with explicit credential/network requirements; packaged Linux launcher test. |
| Future enhancement | Central enterprise ingestion and additional agent adapters | Build on authenticated identity and typed audit events after blockers are closed. Secrets, MCP credentials and wallets remain out of scope for this pass. |

See [the criterion matrix](runtime-acceptance.md), [the attack inventory](adversarial-inventory.md), and the appended [phase-10 completion notes](../rv-agent/handoffs/phase-10-contained-host-launch.md).
