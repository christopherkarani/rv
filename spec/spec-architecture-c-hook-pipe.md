---
title: C hook pipe with XPC evaluate and Swift miss fallback
version: 1.0
date_created: 2026-08-21
last_updated: 2026-08-21
owner: rv
tags:
  - architecture
  - infrastructure
  - design
  - hook
  - xpc
---

# Introduction

This specification defines a two-binary hook path for rv. The file that hosts spawn, `$HOME/.local/bin/rv`, becomes a small C program that forwards a host hook event to `rvd` over XPC and writes the host wire bytes that `rvd` returns. When XPC is down, skewed, timed out, or otherwise unusable, the C program executes the Swift operator binary (`rv-cli`) with the same `hook` argv and a replay of stdin. The Swift program evaluates in-process. A Decision must not become allow because XPC missed.

Measured on the development machine on 2026-08-21, a warm Grok `rv hook` (release, `rvd` up) is about 11 ms median. The C pipe target is about 4 ms median on the same machine class when `rvd` is already running (about −65% versus 11 ms). That number is a target, not a ticket gate. A Decision, miss-policy, or host-wire regression fails the ticket.

# 1. Purpose & Scope

## Purpose

Reduce per-tool-call hook latency for Grok, Pi, and OpenCode shell hooks without changing product law: down or skew still evaluates; `indeterminate` still host-denies; there is no environment variable that skips evaluate.

## Audience

Implementers of rv (Swift 6.3.3, macOS 26, Apple Silicon) and reviewers using `implement-spec` / `swift-architecture-pipeline`.

## In scope

- C program installed as `rv` that handles `hook` by XPC pipe.
- Swift executable staged and installed as `rv-cli` (today’s SPM product `rv`).
- Additive `rv.ipc.v1` method `hookEvaluate` (host + stdin in, host wire + exit code out).
- `rvd` running codecs + gated evaluate and returning the exact host stdout.
- Miss path: `exec` `rv-cli hook …` with stdin replay.
- `install.sh`, `tools/release.sh`, setup baked path, doctor executable check.
- Merge plan for `RVService` → `RVHooks` and the install layout.

## Out of scope

- KeepAlive / always-on `rvd`. Idle-exit about 5 minutes stays.
- Thin Swift hook executable (former T15 fence). Do not retarget the SPM `rv` product to drop ArgumentParser or TUI.
- A second pattern matcher in C. C does not normalize, quick-reject, compile ICU, or decide allow versus deny.
- Host adapters changing argv. They still spawn `$HOME/.local/bin/rv hook --host {grok,pi,opencode}`.
- Zig, Rust, or a second toolchain.
- Raising host hook timeouts (Grok remains 5 s).
- Analytics, PostHog, or CFNetwork changes except that the C hook process must not link them.
- Unix sockets in production `rvd`.
- Linux, Windows, Intel, macOS 14/15.

## Assumptions

- T10–T14 are on the integration branch: release artifacts, enabled-only compile, hook argv fast-path in Swift, allow-path I/O skip, one-shot evaluate with `clientSemver` and major-semver refusal.
- Protocol name stays `rv.ipc.v1`. New method and fields are additive.
- Day-one enabled packs remain `core.git` and `core.filesystem`.
- Display `rule_id` is slash form (`core.git/reset-hard`). Robot JSON `rule_id` is colon form.

# 2. Definitions

| Term | Meaning |
|---|---|
| **C hook** | The C program installed at `$HOME/.local/bin/rv`. |
| **`rv-cli`** | The Swift operator binary (SPM product still named `rv`). Installed next to the C hook as `rv-cli`. Owns `test`, `setup`, `doctor`, `packs`, `explain`, `allow-once`, and the Swift `hook` miss path. |
| **Host** | One of `grok`, `pi`, `opencode`. |
| **Host stdin** | The raw bytes the host writes to the hook process stdin. |
| **Host wire** | The exact stdout bytes and process exit code a host adapter already expects from `rv hook --host …`. |
| **Pipe path** | C hook sends `hookEvaluate` to `rvd` and writes the reply stdout / exit code. |
| **Miss path** | C hook executes `rv-cli` with `hook` argv and replays host stdin. Swift evaluates in-process (existing `ServiceClient` / `GatedEvaluate` law). |
| **XPC** | macOS Cross-Process Communication. Production transport is Mach service `dev.rv.evaluate`. |
| **`rvd`** | The on-demand LaunchAgent that listens on `dev.rv.evaluate`. |
| **One-shot** | A single XPC `perform` that carries implicit hello via `clientSemver`. Budget 700 ms (200 ms connect + 500 ms request). |
| **Skew** | Protocol name mismatch, major semver mismatch, or `HelloAck.ok == false`. Do not evaluate against a skewed listener. |
| **Decision** | Closed enum `allow` / `deny(Deny)` / `indeterminate(IndeterminateReason)`. |
| **`hostDenyText`** | One-line host deny string produced in Swift (`RVHooks`). Nil only after switching on `Decision` for allow. |
| **Day-one packs** | `core.git` and `core.filesystem`. |
| **KeepAlive** | launchd key that respawns a job immediately. Forbidden as the default for `rvd`. |

# 3. Requirements, Constraints & Guidelines

## Functional

- **REQ-001**: Hosts spawn `$HOME/.local/bin/rv hook --host {grok,pi,opencode}`. That path must keep working. Do not change adapter templates to a different executable name.
- **REQ-002**: When argv is a hook path (first token `hook`, and the argv is not a help path), the C hook takes the pipe path. Help paths (`-h`, `--help` anywhere HelpDispatch already treats as help) must not take the pipe path.
- **REQ-003**: Pipe path: parse `--host` / `--host=` the same way Swift `Hook` does (default `grok`). Read stdin. Send one `hookEvaluate` XPC frame with `clientSemver` set to `ProtocolVersion.serviceSemver`. Write reply `stdout` to stdout. Exit with reply `exitCode`.
- **REQ-004**: Invalid `--host` value must not evaluate. The C hook shall execute `rv-cli` with the same argv so ArgumentParser remains the single invalid-host implementation.
- **REQ-005**: Any non-hook argv (`test`, `setup`, `doctor`, `packs`, `explain`, `service`, `allow-once`, `allowlist`, uninstall, bare `rv`) shall execute `rv-cli` with the same argv, environment, working directory, and inherited stdin/stdout/stderr.
- **REQ-006**: Miss path triggers: connect failure, timeout, interrupt, decode failure, unexpected reply shape, protocol skew, major semver skew on `serviceSemver` when present, `handshakeOK` / implicit hello failure, missing sibling `rv-cli`. Miss shall not allow.
- **REQ-007**: Miss path shall `exec` (or spawn-and-wait only if exec is impossible after stdin was consumed) `rv-cli hook --host <same>` and replay the exact stdin bytes already read. Swift `Hook` / `ServiceClient` then evaluates (XPC or in-process per existing law).
- **REQ-008**: `rvd` `hookEvaluate` shall decode host stdin with the existing Swift codec for that host, run gated evaluate (session then policy), encode the host wire with that codec, and return stdout + exitCode. Codecs copy `hostDenyText`. They do not invent a second deny sentence.
- **REQ-009**: `hookEvaluate` uses the same implicit-hello rules as T14 evaluate: `clientSemver` present and `handshakeOK == false` → acknowledge; `ok == false` → error, do not evaluate; major semver mismatch is skew.
- **REQ-010**: `git reset --hard` remains deny `core.git:reset-hard`. `git stash drop` remains allow + match with empty host stdout. Oversize / missing core remains indeterminate → host deny with the incomplete-eval sentence and no pack `rule_id`.
- **REQ-011**: Empty / non-shell host stdin remains empty allow (exit 0, empty stdout) on the pipe path and the miss path.
- **REQ-012**: `rvd` remains on-demand, idle-exit about 300 s, KeepAlive false, `RunAtLoad` false.

## Security

- **SEC-001**: Never allow because XPC missed. Miss evaluates in Swift.
- **SEC-002**: Do not evaluate against a skewed `rvd`.
- **SEC-003**: No `RV_BYPASS` and no other environment variable the hook child honors to skip evaluate.
- **SEC-004**: The C hook shall not parse host JSON to extract a command. It shall not implement normalize, quick-reject, ICU, or Decision.
- **SEC-005**: The C hook shall not write command text, paths, or secrets to `os_log` or any log.
- **SEC-006**: Host hook processes shall not call analytics and shall not link CFNetwork.
- **SEC-007**: C shall reject stdin that contains a NUL byte and take the miss path (replay is still possible as raw bytes to `rv-cli`; do not put NUL into a JSON string).
- **SEC-008**: C shall JSON-escape the stdin field with a dedicated escape routine covered by tests (quotes, backslashes, controls, UTF-8). A broken escape is a security defect.
- **SEC-009**: If stdin length exceeds 1 048 576 bytes, take the miss path. Do not truncate.

## Constraints

- **CON-001**: Protocol stays `rv.ipc.v1`. Do not bump to `v2`.
- **CON-002**: Production transport is Mach / XPC `dev.rv.evaluate`. No Unix socket in production `rvd`.
- **CON-003**: One-shot budget remains 700 ms. Do not raise host adapter timeouts.
- **CON-004**: C is compiled with the platform `clang` (Apple Silicon, macOS 26). No Swift runtime, no Foundation, no ArgumentParser in the C hook.
- **CON-005**: C is not an SPM executable product. `Package.swift` product `rv` remains the Swift operator (staged as `rv-cli`).
- **CON-006**: `RVService` may gain a dependency on `RVHooks` for the hook door only. `RVHooks` still must not evaluate and must not import CLI, TUI, Presentation, or Service.
- **CON-007**: `RVEngine` must not import XPC, IPC transport, CLI, or TUI.
- **CON-008**: Do not set KeepAlive true. Do not add a second matcher. Do not retarget SPM `rv` away from TUI/ArgumentParser.
- **CON-009**: Do not write either banned host-product token (see PLAN name-hygiene law; both are two-to-three-letter lowercase product names) in any file this wave touches outside `docs/factory/`.
- **CON-010**: Tests use a temp `HOME`. No live-HOME writes. No `NSHomeDirectory()` as a fixture root.

## Guidelines

- **GUD-001**: Latency target: warm Grok allow/deny about 4 ms median on the same machine class as the 2026-08-21 11 ms measurement. Do not fail a ticket because the number is 1 ms off. Fail if Decision, miss policy, or host wire regresses.
- **GUD-002**: Prefer `execve` of `rv-cli` over spawn-and-wait. After stdin was consumed, open a pipe to the child stdin and exec only if a wrapper is required; a small C helper that forks, writes stdin, and execs `rv-cli` is acceptable.
- **GUD-003**: Sibling resolution: directory of `argv[0]` after realpath, then `$HOME/.local/bin/rv-cli`. If neither is executable, write nothing that looks like allow; exit nonzero. Doctor reports `broken`.
- **GUD-004**: Invalid host and help stay on `rv-cli` so there is one help page and one invalid-host message.

## Patterns

- **PAT-001**: Switch on `Decision` in Swift only. C never infers allow from empty stdout.
- **PAT-002**: Additive IPC: `decodeIfPresent` / new `IPCMethod` case `hookEvaluate`. Old clients that never send it keep working.
- **PAT-003**: Canonical deny line (copy, do not paraphrase): `Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once.`
- **PAT-004**: Incomplete-eval sentence (copy): `rv could not finish evaluating this command. Run it in Terminal.`
- **PAT-005**: Merge plan (this spec is the plan): (1) `Package.swift` — `RVService` may list `RVHooks`; no new executable product. (2) Install layout — `rv` is C, `rv-cli` is Swift, `rvd` unchanged. (3) `ServiceRuntime` — T2 of this spec owns `hookEvaluate` dispatch; do not reformat the whole file.

# 4. Interfaces & Data Contracts

## 4.1 Process argv

| Argv | Actor | Behavior |
|---|---|---|
| `rv hook` / `rv hook --host grok` | C hook | Pipe path (default host grok) |
| `rv hook --host=pi` | C hook | Pipe path |
| `rv hook --help` / `rv hook -h` | C hook | Execute `rv-cli` (HelpDispatch) |
| `rv hook --host nope` | C hook | Execute `rv-cli` (no evaluate) |
| `rv test …` / `rv setup` / `rv doctor` / other | C hook | Execute `rv-cli` with same argv |
| `rv-cli hook --host grok` | Swift | Existing `HookDispatch` + `ServiceClient` (used on miss) |

Host adapter command remains:

```
__RV_BINARY__ hook --host grok
```

`__RV_BINARY__` resolves to `$HOME/.local/bin/rv` (the C hook).

## 4.2 Additive IPC method `hookEvaluate`

Request body is existing `IPCRequest` with `method.hookEvaluate`:

```json
{
  "id": "<uuid>",
  "protocolName": "rv.ipc.v1",
  "method": {
    "hookEvaluate": {
      "host": "grok",
      "stdin": "<raw host stdin as a JSON string>",
      "clientSemver": "1.0.0"
    }
  }
}
```

| Field | Type | Rules |
|---|---|---|
| `host` | string | `grok` \| `pi` \| `opencode`. Unknown host → `IPCError` (do not evaluate). |
| `stdin` | string | Full host stdin. Required. May be empty. |
| `clientSemver` | string? | Required for implicit hello (same as T14 evaluate). Omit → handshake-required error if `handshakeOK` is false. |

Success reply:

```json
{
  "id": "<same>",
  "protocolName": "rv.ipc.v1",
  "result": {
    "hookEvaluate": {
      "stdout": "<host wire bytes as UTF-8 string>",
      "exitCode": 0,
      "via": "xpc",
      "serviceSemver": "1.0.0"
    }
  }
}
```

| Field | Type | Rules |
|---|---|---|
| `stdout` | string | Exact host stdout. Empty on allow. |
| `exitCode` | number | Same `Int32` the Swift hook already uses (Grok deny is 0). |
| `via` | string | Must be `"xpc"` on the wire. |
| `serviceSemver` | string? | Additive. When present, C must apply `ProtocolVersion.isMajorSkew` and miss if skewed. |

Skew / unready: existing `result.error` with protocol-skew message. Do not include a `hookEvaluate` result. C takes the miss path.

Old `evaluate` / Hello remain for `rv-cli`, status, doctor, and tests.

## 4.3 Swift hook door (server)

`RVService` owns a value-type door, for example `HookDoor`, that:

1. Maps `host` to `GrokHostCodec` / `PiHostCodec` / `OpenCodeHostCodec`.
2. Calls existing `HookRun.run(stdin:codec:evaluate:)` or an equivalent that lives in Service and only uses `RVHooks` codecs + `GatedEvaluate`.
3. Does not import ArgumentParser, TUI, or Presentation.

`HookRun` may move from `RVCLI` into `RVService` (or a thin shared function). `RVCLI` then calls the Service door for the Swift miss path, or keeps a local wrapper that calls the same codecs + `ServiceClient.evaluateResult` (miss already goes through `ServiceClient`; do not duplicate Decision logic).

Preferred miss implementation: `rv-cli hook` stays as today (`ServiceClient` one-shot evaluate + local codecs). C does not need `HookDoor` on the client. `HookDoor` is server-only.

## 4.4 Install and release layout

`tools/release.sh` stages:

| Name | Kind |
|---|---|
| `rv` | C hook, `clang -Os`, stripped |
| `rv-cli` | current SPM `rv` after `strip -x` |
| `rvd` | current SPM `rvd` after `strip -x` |
| `*_RVPacks.bundle` | unchanged; required next to `rvd` and `rv-cli` |

`install.sh` copies `rv`, `rv-cli`, `rvd`, and pack bundles into `$HOME/.local/bin`. Requires all three executables. `RV_FROM_INSTALL=1 exec "$bin/rv" setup` stays (C execs `rv-cli setup`).

Setup still bakes `$HOME/.local/bin/rv` into host adapters.

Doctor: missing or non-executable baked `rv` is `broken`. Also `broken` if `rv-cli` is missing next to `rv` (miss path cannot run).

## 4.5 C Mach client

- Service name: `dev.rv.evaluate` (same as `RVService.machServiceName`).
- One connection, one message, then teardown.
- Timeout 700 ms total.
- Payload: UTF-8 JSON `IPCRequest` bytes, same envelope `IPCJSON` already uses.
- Do not use `NSXPCConnection` (that is Foundation).

# 5. Acceptance Criteria

- **AC-001**: Given a warm `rvd` and Grok deny fixture `git reset --hard`, when `$HOME/.local/bin/rv hook --host grok` reads that stdin, then stdout is the existing Grok deny JSON, `reason` is the canonical deny line, exit is 0, and the process image is the C hook (not `rv-cli`).
- **AC-002**: Given the same setup and Grok allow fixture `git status` (or `git stash drop`), when the C hook runs, then stdout is empty and exit is 0.
- **AC-003**: Given `rvd` down or a major-semver-skewed listener, when the C hook receives `git reset --hard`, then the process takes the miss path and the Decision is still deny `core.git:reset-hard` with the canonical host line. The result is not allow.
- **AC-004**: Given `rvd` down, when the C hook receives empty-allow / non-shell stdin, then the miss path still produces empty stdout exit 0.
- **AC-005**: Given `rv hook --help`, when the C hook runs, then output is the existing HelpDispatch page and no `hookEvaluate` is sent.
- **AC-006**: Given `rv test --robot --plain 'git reset --hard'`, when `rv` is the C hook, then `rv-cli` runs and the robot Decision is deny.
- **AC-007**: Given a temp HOME install, when `install.sh` runs with staged artifacts, then `rv`, `rv-cli`, `rvd`, and pack bundles are present and `rv setup` still writes adapters that spawn the C `rv hook`.
- **AC-008**: Given doctor, when `rv-cli` is missing or not executable, then the report is `broken`, not `wired`.
- **AC-009**: Given `hookEvaluate` without `clientSemver` and no prior Hello, when `rvd` handles the body, then it returns handshake-required and does not evaluate.
- **AC-010**: Given an old client that only sends `evaluate`, when it talks to a new `rvd`, then evaluate still works (additive method).
- **AC-011**: The system shall not read or honor `RV_BYPASS` or any skip-evaluate environment on the C hook or `rv-cli hook`.
- **AC-012**: Given stdin larger than 1 048 576 bytes or containing NUL, when the C hook runs, then it does not send a truncated JSON `hookEvaluate`; it takes the miss path.

## 5b. Tickets (task graph)

```
T1 IPC hookEvaluate
T2 rvd HookDoor          (blocked by T1)
T3 C hook + release.sh   (blocked by T1)
        │
        ▼
T4 install / setup / doctor   (blocked by T3)
T5 process proof              (blocked by T2 and T4)
```

Wave 1 after T1 merges: **T2 ∥ T3**. Wave 2: **T4**. Wave 3: **T5**.

| id | title | depends-on | exclusive-writes | acceptance | review-hint |
|---|---|---|---|---|---|
| **T1** | Additive `hookEvaluate` types and JSON round-trip on `rv.ipc.v1` | none | `Sources/RVIPC/IPCMethods.swift` (new types + `IPCMethod` / `IPCResult` cases only); `Tests/RVIPCTests/HookEvaluateRoundTripTests.swift` (new) | Decode/encode host+stdin+clientSemver; omitted `clientSemver` is nil; old evaluate envelopes still decode; unknown method still errors | `101–1499` |
| **T2** | `rvd` hook door: codecs + gated evaluate + implicit hello | T1 | `Package.swift` (`RVService` dependencies only: add `RVHooks`); `Sources/RVService/HookDoor.swift` (new); `Sources/RVService/ServiceRuntime.swift` (`handleIncoming` / `acknowledge` / dispatch `hookEvaluate` only); `Tests/RVServiceTests/HookEvaluateTests.swift` (new) | Implicit hello + `git reset --hard` returns Grok deny wire; major semver does not evaluate; missing `clientSemver` is handshake-required; `git stash drop` empty stdout | `101–1499` |
| **T3** | C hook binary and `tools/release.sh` stage `rv` + `rv-cli` | T1 | `Sources/rv-c/` (new); `tools/release.sh`; `tools/README.md` (inventory rows only); `docs/dev/SWIFT.md` (release table only) | `clang` produces a Mach-O that does not list Foundation or CFNetwork; release stages `rv` (C), `rv-cli` (Swift), `rvd`; JSON escape unit tests in `Sources/rv-c/tests/` or a tiny C test binary | `≤100` (Swift); C is out of Swift review buckets |
| **T4** | Install, setup bake, doctor `rv-cli` | T3 | `install.sh`; `Sources/RVCLI/Setup/SetupRun.swift` (path comments / copy if needed); `Sources/RVCLI/Setup/OwnedPaths.swift`; `Sources/RVCLI/Doctor/DoctorRun.swift` (`rv-cli` missing → `broken`); matching `Tests/RVCLITests` setup/doctor tests | Temp-HOME install copies three executables; adapters still contain `…/rv hook --host`; missing `rv-cli` is `broken` | `101–1499` |
| **T5** | Process proof: pipe, miss, help, operator argv | T2, T4 | `Tests/RVCLITests/CHookPipeTests.swift` (new) or `tools/c-hook-proof.sh` (new) plus fixtures only under `Tests/` | AC-001…AC-006 against staged binaries and a temp HOME; `tools/gate.sh` for `RVIPCTests RVServiceTests RVCLITests RVHooksTests` | `101–1499` |

**`ServiceRuntime.swift` partition:** T2 only adds a `hookEvaluate` branch next to existing evaluate dispatch. Do not reformat the file. Do not change T11 compile functions or T14 evaluate implicit-hello except to share acknowledge.

**`Package.swift`:** T2 is the only ticket that may add `RVHooks` to `RVService`. No new products.

# 6. Test Automation Strategy

- **Test Levels**: Unit (IPC round-trip, C JSON escape, HookDoor in-process); Integration (ServiceRuntime Unix-socket test helper already used for one-shot evaluate); Process (staged `rv` C + `rvd` + fixtures).
- **Frameworks**: Swift Testing (`import Testing`) for Swift. C escape tests: a small `clang` test binary invoked from `tools/c-hook-proof.sh` or T5. No XCTest.
- **Test Data Management**: Existing Grok/Pi/OpenCode fixtures under `Tests/RVHooksTests/Fixtures/`. Temp `HOME`. No live HOME.
- **CI/CD Integration**: `tools/gate.sh` for touched `*Tests`. T5 proof script is part of gate or a documented extra step in the ticket prove list.
- **Coverage Requirements**: No new percentage gate. Required cases: deny `git reset --hard`, allow `git stash drop` / `git status`, miss deny, help, invalid host, oversize stdin miss, additive old evaluate.
- **Performance Testing**: Record warm Grok allow/deny p50 on the development machine after T5. Target about 4 ms. Do not fail CI on 1 ms variance.

# 7. Rationale & Context

Warm hook time on this machine is about 11 ms: about 5 ms to start a Swift process, about 2 ms codec/client, about 4 ms XPC evaluate. A smaller Swift binary does not remove the Swift/Foundation start cost (about −5%). Keeping `rvd` always running does not remove the Swift start cost (about 0% on a busy session). A host-side XPC client could be faster (about −75% to −90%) but duplicates miss law in JavaScript/TypeScript.

A C program that does not load Swift can start in the about 2 ms class (`/usr/bin/true` is about 1.9 ms). Combined with a warm `rvd`, the honest band is about 3–5 ms (about −55% to −75% versus 11 ms). The miss path stays Swift so there is no second engine and no allow-on-miss.

C must not parse host JSON because a parse bug is a security defect. `rvd` already has codecs and `GatedEvaluate`. The new method is a pipe: host bytes in, host bytes out.

`hookEvaluate` is a new method rather than overloading `evaluate`, so existing one-shot evaluate clients stay valid and the server can refuse unknown hosts without touching `EvaluationRequest`.

SPM keeps product `rv` as Swift so ArgumentParser/`@main` law does not move. Install renames the staged Swift binary to `rv-cli`. Hosts keep spawning `rv hook`.

# 8. Dependencies & External Integrations

### External Systems

- **EXT-001**: Host hook runners (Grok, Pi, OpenCode) — spawn the baked `rv hook --host …` command and honor the existing host wire. No adapter rewrite.

### Third-Party Services

- None. Hook processes must not call analytics.

### Infrastructure Dependencies

- **INF-001**: User LaunchAgent `dev.rv.evaluate` — on-demand Mach listener, idle-exit about 5 minutes, KeepAlive false.
- **INF-002**: `$HOME/.local/bin` install prefix — `rv`, `rv-cli`, `rvd`, pack bundles.

### Data Dependencies

- **DAT-001**: Bundled pack JSON (`*_RVPacks.bundle`) — required for `rvd` and for Swift miss evaluate.
- **DAT-002**: Host adapter fixtures under `Tests/RVHooksTests/Fixtures/` — stdin/stdout/exit oracles.

### Technology Platform Dependencies

- **PLT-001**: macOS 26, Apple Silicon, Swift 6.3.3 language mode 6 — existing pin.
- **PLT-002**: Host `clang` for the C hook — no extra compiler distribution.
- **PLT-003**: libSystem / XPC C API — no Foundation.

### Compliance Dependencies

- **COM-001**: Product law in `docs/factory/PLAN.md` — down/skew evaluate, no skip-evaluate env, no command text in logs, no OS-enforced / Seatbelt claim.

# 9. Examples & Edge Cases

```text
# Pipe deny (rvd up)
printf '%s' '<grok deny-git-reset-hard.json>' | rv hook --host grok
# stdout: Grok deny JSON, reason = canonical deny line
# exit: 0
# send count to rvd: 1

# Pipe allow
printf '%s' '<grok allow-git-status.json>' | rv hook --host grok
# stdout: empty
# exit: 0

# Miss deny (rvd down or major skew)
# C execs rv-cli hook --host grok with the same stdin
# Decision still deny core.git:reset-hard
# Must not be empty allow

# Help must not pipe
rv hook --help
# HelpDispatch page; hookEvaluate not sent

# Operator argv
rv test --robot --plain 'git reset --hard'
# exec rv-cli; robot deny

# Oversize / NUL stdin
# C does not send hookEvaluate; miss to rv-cli

# Old evaluate client
# Hello+evaluate or one-shot evaluate without hookEvaluate still works
```

# 10. Validation Criteria

- [ ] Hosts still spawn `$HOME/.local/bin/rv hook --host {grok,pi,opencode}`.
- [ ] Warm pipe deny/allow matches existing fixtures (AC-001, AC-002).
- [ ] Down and major-semver skew still deny `git reset --hard` (AC-003).
- [ ] Help and invalid host do not evaluate (AC-005, REQ-004).
- [ ] `rv test` / `rv setup` still work via `rv-cli` (AC-006, AC-007).
- [ ] Missing `rv-cli` is doctor `broken` (AC-008).
- [ ] `hookEvaluate` is additive; old evaluate remains (AC-009, AC-010).
- [ ] No skip-evaluate environment (AC-011).
- [ ] C binary has no Foundation / CFNetwork (`otool -L`).
- [ ] KeepAlive remains false. No second matcher. No SPM `rv-hook` product.
- [ ] `tools/gate.sh --quiet RVIPCTests RVServiceTests RVCLITests RVHooksTests` green after T5.
- [ ] Warm Grok p50 recorded; target about 4 ms; not a fail-the-ticket number.

# 11. Related Specifications / Further Reading

- `docs/factory/PLAN.md` — product law (down/skew evaluate, no skip-evaluate env).
- `docs/factory/specs/phase-5-size-speed.md` — T10–T14 landed; T15 thin Swift hook is superseded by this spec (do not implement that fence).
- `docs/factory/specs/phase-1c-service.md` — `rv.ipc.v1`, on-demand `rvd`, timeouts.
- `docs/factory/specs/phase-1d-hosts.md` — host spawn argv and wire.
- `docs/factory/references/host-contracts-v1.md` — canonical deny line.
- `docs/architecture/MODULES.md` — module arrows; this spec adds `RVService` → `RVHooks`.
- `.grok/skills/swift-hexagonal-spm/references/package-ownership.md` — merge-plan trigger; this spec is the merge plan.
- `.grok/skills/swift-hook-xpc/SKILL.md` — Decision switch, miss law, doctor `broken`.
- `docs/dev/SWIFT.md` — release artifact table (T3 updates sizes).
