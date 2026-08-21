# Phase 5 — Size and hook speed (T10–T14)

Implement spec. Outcome: release artifacts that relocate, compile only enabled packs, a cheaper `rv hook` spawn, less allow-path I/O, one XPC round-trip on evaluate.

T0–T9 are **done**. This is a maint wave. It does **not** reopen Phase 4+. It does **not** change PLAN product law.

Repo: `~/CodingProjects/rv`. Never implement inside ryk.

Source of truth: `docs/factory/PLAN.md`. This spec is the T10–T14 implement prompt. Ticket prompts: `docs/factory/prompts/T10.md` … `T14.md`.

Gate: **L1** for T11–T14. **L4-shaped** (temp HOME, relocated binaries) for T10. Corpus stays green (`tools/gate.sh --quiet RVEngineTests RVCorpusTests`) after T11.

## Goal

Make the shipped hook child smaller and the hook path faster **without** changing a Decision.

Measured on this machine 2026-08-21 (installed `~/.local/bin`, **debug `-Onone`**):

| Fact | Number |
|---|---|
| `rv` | 6.5 MB; `__TEXT` 3.0 MB; `__LINKEDIT` 3.5 MB; `libswiftSwiftOnoneSupport` |
| `rvd` | 2.1 MB |
| `strip -x` copies | 4.2 MB / 1.3 MB |
| Catalog JSON | 861 KB, 99 packs, 1,887 ICU patterns (day-one: 81) |
| Explanation essays | 333 KB (39% of JSON) |
| Warm Grok `rv hook` | 9–11 ms (spawn ~8 ms + XPC ~2 ms) |
| First hook after idle-exit | 62 ms |
| `rv test --robot` (new process, compile-all) | ~18 ms |
| Grok host timeout | 5 s (do not raise) |

Day-one win this wave unlocks: a **release** `rv` / `rvd` that still evaluates after the build tree is gone; a miss/cold path that compiles **enabled** packs (default two), not 99; a hook spawn that does not parse the full ArgumentParser tree; an evaluate that is **one** XPC `perform` after connect.

## Non-goals

- `KeepAlive` / always-on `rvd`. Idle-exit ~5 minutes stays.
- Raising Grok / Pi / OpenCode hook timeouts.
- Rewriting or “simplifying” pack regexes. Parity pin stays 0.11.0.
- A second executable (`rv-hook`) or a `Package.swift` graph edit. **T15 fence** below.
- Splitting pack essays out of catalog JSON. **Later.**
- Analytics / PostHog protocol changes. Debounce is allowed only as named in T13; no new events.
- `RV_BYPASS` or any hook-child env that skips evaluate.
- Allow-because-XPC-missed. Down/skew still in-process evaluate.
- Unix-socket production transport.
- Thin-client rewrite of host adapters (they still spawn `rv hook --host …`).
- Merging modules, wiping `.build`, or `swift package clean` to “prove” size.
- Linux / Windows / Intel / macOS 14/15 claims.
- Writing the tokens `dcg` or `ryk` outside `docs/factory/`.

## Depends on

| Ticket | Why this wave needs it |
|---|---|
| **T0–T9** | Graph, evaluate, `rvd`, `rv hook`, setup, catalog. All landed. |

Do not start T10–T14 product code before T9 catalog load is green.

This wave consumes, does not redefine:

- `Decision`, `PackID`, `RuleID`, `ShellCommand`, `EvaluationRequest`, `EvaluationResult`
- `evaluate` order: normalize → quick-reject → safe → destructive → default allow
- Day-one packs `core.git` + `core.filesystem`; empty `enabledPacks` means none
- `rv.ipc.v1` method set (additive optional fields only)
- Connect 200 ms / request 500 ms then in-process
- Host adapters spawn `$HOME/.local/bin/rv hook --host {grok,pi,opencode}`

## Ticket graph

Tickets are a **task graph**, not a checklist. Frontier = tickets with no open blocker.

```
T10 release artifacts          (no blocker)
T11 enabled-only compile       (no blocker)
T12 hook argv fast-path        (no blocker)
T13 allow-path I/O             (no blocker)
        │
        ▼
T14 one-shot evaluate          (blocked by T11)
```

Wave 1 (parallel worktrees, same base SHA): **T10 ∥ T11 ∥ T12 ∥ T13**.

Wave 2: **T14** after T11 is merged (both touch `ServiceRuntime` session lifetime).

implement-spec: one integration branch (`feat/t10-t14-size-speed`) that closes this spec. Each ticket lands on its own `feat/tN-…` worktree and merges into that branch. Do not share a working tree across tickets.

## Parallel / file ownership

They must not share a working tree. Exclusive paths:

| Ticket | Branch | Owns | Must not |
|---|---|---|---|
| **T10** | `feat/t10-release` | `tools/release.sh` (new), `install.sh`, `tools/README.md` (inventory row), `docs/dev/SWIFT.md` (release/size table **only**) | `Sources/`, `Tests/`, `Package.swift` |
| **T11** | `feat/t11-compile` | `Sources/RVService/EvaluateSession.swift`, `Sources/RVService/CoreWarmup.swift`, `Sources/RVService/ServiceRuntime.swift` (`init` + `setPackEnabled` + `gated` storage **only**), `Tests/RVServiceTests/EvaluateSessionTests.swift`, new `Tests/RVServiceTests/EnabledCompileTests.swift` | `RVCLI`, `RVIPC`, `Sources/rv`, `install.sh`, `GatedEvaluate.swift` apply/peek bodies, `Package.swift` |
| **T12** | `feat/t12-hook-dispatch` | `Sources/rv/main.swift`, `Sources/RVCLI/Hook/HookDispatch.swift` (new), `Tests/RVCLITests/HookDispatchTests.swift` (new) | `EvaluateSession`, `ServiceRuntime`, `RVIPC`, `install.sh`, `Package.swift` products |
| **T13** | `feat/t13-allow-io` | `Sources/RVService/GatedEvaluate.swift`, `Sources/RVService/PacksFacade.swift` (`effectiveIDs` only), `Tests/RVServiceTests/GatedEvaluateTests.swift`, `Tests/RVServiceTests/PacksFacadeTests.swift` if present or new | `EvaluateSession` compile, `ServiceRuntime` dispatch/hello, `Sources/rv`, `RVIPC`, `install.sh` |
| **T14** | `feat/t14-oneshot` | `Sources/RVIPC/IPCMethods.swift` (`EvaluateParams` additive field), `Sources/RVCLI/Service/XPCClient.swift`, `Sources/RVCLI/Service/ServiceClient.swift` (`evaluate` / `route` **only**), `Sources/RVService/ServiceRuntime.swift` (`handleIncoming` / `acknowledge` / `dispatch` evaluate **only**), matching IPC + CLI + Service tests | `EvaluateSession` compile policy, `GatedEvaluate` allowlist skip, `Sources/rv/main.swift`, `install.sh`, `Package.swift` |

**`ServiceRuntime.swift` partition (T11 vs T14 — do not both edit the same functions):**

- **T11 only:** `init`, `setPackEnabled`, the `gated` stored property (may change `let` → `var` and rebuild `GatedEvaluate(EvaluateSession(…))` after enable).
- **T14 only:** `acknowledge`, `handleIncoming`, `dispatch` / `runEvaluate` call site (implicit hello on first evaluate).
- Neither ticket reformats the whole file.

**`Package.swift`:** no ticket in this wave may add a product, target, or dependency.

## Law (copy; do not paraphrase a second deny sentence)

PLAN wins conflicts. Locked lines this wave must not break:

- Down or skew → in-process evaluate. Never allow because XPC missed.
- Do not evaluate against a skewed `rvd`.
- `indeterminate` → hook deny with “rv could not finish evaluating this command. Run it in Terminal.”
- No `RV_BYPASS`.
- `KeepAlive` false. Idle-exit ~5 minutes.
- Day-one missing/unloadable → no `HelloAck.ok`, evaluate `indeterminate(.corePacksUnavailable)`.
- Empty `enabledPacks` means none — not a day-one refill.
- Display `rule_id` slash; robot colon.
- Canonical deny: `Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once.`
- Host hooks never call analytics. No command text in `os_log`.
- Additive optional fields may appear inside `rv.ipc.v1` with `decodeIfPresent` defaults. Do not bump to `rv.ipc.v2` for T14.

## Baseline behavior that must stay green

| Command | Result |
|---|---|
| `git reset --hard` | deny `core.git:reset-hard` |
| `git stash drop` | allow + match (not hook text) |
| Oversize / missing core | indeterminate → hook deny, PLAN sentence, no pack `rule_id` |
| `rvd` down or skew | in-process; still deny `git reset --hard` |
| `rv hook --help` | HelpDispatch page (T12 must not steal this) |

## T10 — Release artifacts

**Blocked by:** none.

Ship a release pair that an operator can copy without the developer `.build` tree.

### Why

Installed `rv` / `rvd` on 2026-08-21 were debug (`libswiftSwiftOnoneSupport`). `install.sh` copies two Mach-Os only. SPM `.copy` pack resources resolve through a baked path into `.build/…/rv_RVPacks.bundle`. Hide that directory and relocated evaluate is not proven.

### Do

1. Add `tools/release.sh` (POSIX bash, `tools/swift-6.3.3`):
   - `swift build -c release --product rv --product rvd` (do **not** `swift package clean`).
   - `strip -x` the two products.
   - Stage into a directory: `rv`, `rvd`, and the SPM resource bundle(s) that `Bundle.module` needs (`rv_RVPacks.bundle` and `rvd_RVPacks.bundle` if both exist; copy whichever the release products actually emit).
   - Print staged paths and `ls -l` sizes.
2. `install.sh`: if `$RV_INSTALL_BIN/<name>_RVPacks.bundle` (or the real staged bundle name) exists, copy it next to `$HOME/.local/bin/{rv,rvd}`. Still refuse non-macOS-26-arm64. Still `RV_FROM_INSTALL=1 exec rv setup`.
3. Prove relocate: copy the staged dir to a **temp** prefix; hide or rename the original `.build/…/*RVPacks.bundle` for the duration of the test; `HOME=<temp>` `rv test --robot --plain 'git reset --hard'` is deny. Restore the bundle path after.
4. Prove not `-Onone`: `otool -L` on staged `rv` and `rvd` must **not** list `libswiftSwiftOnoneSupport`.
5. Document in `docs/dev/SWIFT.md` a short **Release artifacts** table (file sizes from this machine’s `tools/release.sh`, plus “strip -x”, plus “bundle must travel with the binaries”). Do not invent Linux numbers.

### Do not

- Change evaluate, hooks, or IPC.
- Claim a hard MB cap in PLAN. Record measured sizes only.
- Code-sign as a T10 gate (strip will invalidate an existing signature; that is expected).
- Write the operator’s live `~/.local/bin` unless the human asked. Tests use temp dirs + `RV_INSTALL_BIN`.

### Prove

- [ ] `tools/release.sh` produces `rv`, `rvd`, and pack bundle(s) under a stage dir
- [ ] staged binaries have no `libswiftSwiftOnoneSupport`
- [ ] relocate + hidden original bundle still denies `git reset --hard` via `rv test --robot`
- [ ] `install.sh` copies the bundle when present; temp-HOME test
- [ ] no `Sources/` / `Package.swift` diff
- [ ] no `dcg` / `ryk` outside `docs/factory/`

## T11 — Compile only enabled packs

**Blocked by:** none.

`EvaluateSession` must compile ICU patterns for the **enabled** set only. Default-off catalog stays on disk, uncompiled, until enable.

### Why

`EvaluateSession.init` today `loadAll()` then `CompiledPacks.compile` on all 99 packs (1,887 patterns). `evaluate` already filters to `request.enabledPacks`. Compiling the rest does not change a Decision. It dominates `rv test` (~18 ms) and `rvd` cold start (~62 ms first hook).

Today `setPackEnabled` writes config and refreshes `catalog` but does **not** need to recompile because everything is already compiled. After this ticket, enable **must** rebuild the session or a newly enabled pack is a false allow.

### Do

1. `EvaluateSession` gains an explicit enabled set:

   ```swift
   public init(
       snapshots: [PackSnapshot]? = nil,
       enabledPacks: [PackID]? = nil
   )
   ```

   - `snapshots` nil → `(try? PackRegistry.loadAll()) ?? ((try? PackRegistry.loadDayOne()) ?? [])` (same as today).
   - `enabledPacks` nil → `(try? PacksFacade.effectiveIDs(home: processHOME)) ?? dayOnePackIDs`.
   - **Compile** `CompiledPacks.compile(packs: snapshots.filter { enabled.contains($0.id) }, using:)`.
   - Keep the **full** snapshot list for `corePacksAreReady` (core must still be present on disk even if someone disabled them — disable of day-one is a policy question already owned by PackSet; do not invent a new disable rule).
   - `corePacksReady` stays “core snapshots present **and** required compiled rules present **when those rules are in the compiled set’s source snapshots**.” If day-one is in `enabledPacks` (the default), `reset-hard` / `fork-bomb` must still compile or the session is not ready.
   - Expose `package var compiledPackIDs: [PackID]` (sorted) for tests.

2. `ServiceRuntime.init`: build `EvaluateSession(snapshots:snapshots, enabledPacks: catalog.records.filter(\.enabled).map(\.id))` after catalog is known. If catalog is default-constructed empty, pass `dayOnePackIDs` (do not compile 99).
3. `ServiceRuntime.setPackEnabled`: after a successful `PacksFacade.enable/disable` + `makeCatalog`, **rebuild** `gated = GatedEvaluate(EvaluateSession(snapshots: currentSnapshots, enabledPacks: newEnabledIDs))`. Keep enough snapshot state to rebuild (store `[PackSnapshot]` on the runtime, or reload via `PackRegistry.loadAll()`).
4. `gated` may become `var`. Do not change `GatedEvaluate.apply` / `peek` bodies (T13 owns those).

### Do not

- Change `evaluate` order or regex text.
- Treat empty `EvaluationRequest.enabledPacks` as day-one refill (existing test).
- Compile a pack that is not in the enabled set “just in case.”
- Quarantine `reset-hard` or `fork-bomb`.
- Edit `GatedEvaluate.apply`.

### Prove

- [ ] `EvaluateSession(snapshots: all99, enabledPacks: dayOnePackIDs).compiledPackIDs` is exactly the two day-one IDs
- [ ] that session still denies `git reset --hard` and allows `git stash drop` as allow+match
- [ ] `EvaluateSession(snapshots: all99, enabledPacks: dayOne + [someCatalogID])` has three compiled IDs and can deny a fixture from that extra pack if the corpus has one; if the extra pack has no safe command in-repo, assert compiled count + a destructive pattern `matches` via the engine, not a marketing Decision
- [ ] `setPackEnabled` enable then evaluate a command that only the new pack denies (or compiledPackIDs grows); disable shrinks compiledPackIDs
- [ ] `EvaluateSession.missingCore` / `uncompilableCore` still indeterminate, not allow
- [ ] `tools/gate.sh --quiet RVServiceTests RVEngineTests RVCorpusTests`
- [ ] no regex in the diff was simplified

## T12 — Hook argv fast-path

**Blocked by:** none.

`rv hook` must not construct the full ArgumentParser command tree.

### Why

`Sources/rv/main.swift` already short-circuits help via `HelpDispatch.tryEmit`. Hook still falls through to `await RV.main()` which registers test/explain/packs/setup/doctor/…. Warm-hook spawn is ~8 ms; most of a warm hook is that spawn, not evaluate.

### Do

1. Add `Sources/RVCLI/Hook/HookDispatch.swift`:
   - `public enum HookDispatch`
   - `public static func matches(_ arguments: [String]) -> Bool` — first token is `hook`, and the rest is **not** a help path (`-h` / `--help` anywhere that HelpDispatch already treats as help).
   - `public static func run(arguments: [String]) async` — parse `--host` / `--host=` the same way `Hook` does today (default `.grok`); read stdin; call the existing `Hook.run` / `HookRun.run` + `ServiceClient` path; write stdout/stderr; exit with the wire `exitCode` (same `ExitCode` behavior).
   - Invalid `--host` value: same failure as ArgumentParser would (nonzero exit, no evaluate). Do not invent a new host.
2. `Sources/rv/main.swift` order stays:

   ```
   if HelpDispatch.tryEmit(arguments: args) { return }
   if HookDispatch.matches(args) { await HookDispatch.run(arguments: Array(args.dropFirst())); return }
   await RV.main()
   ```

3. `struct Hook: AsyncParsableCommand` **stays** so `rv help hook` / `rv --help` and accidental `RV.main()` still work. T12 does not delete the subcommand.

### Do not

- Change codecs, `hostDenyText`, or evaluate.
- Skip HelpDispatch. `rv hook --help` remains the pretty/robot help page.
- Add `RV_BYPASS`.
- Add a new executable.

### Prove

- [ ] `HookDispatch.matches(["hook"])` true; `matches(["hook","--help"])` false; `matches(["test"])` false
- [ ] In-process: `HookDispatch` + injected evaluate still deny `git reset --hard` / allow `git stash drop` for grok stdin (`pre_tool_use` + `Bash`)
- [ ] Process (if `rv` is built): `rv hook --host grok` with allow stdin → empty stdout exit 0; deny stdin → deny JSON exit 0
- [ ] `rv hook --help` still goes through HelpDispatch (no ArgumentParser error)
- [ ] `tools/gate.sh --quiet RVCLITests RVHooksTests`

## T13 — Skip allow-path I/O

**Blocked by:** none.

Allow results must not read the allowlist file. Missing `config.toml` must not parse the pack index just to return day-one IDs.

### Why

`GatedEvaluate.apply` / `peek` always `AllowlistStore.loadUserSnapshot` **after** evaluate, then `PolicyGate` ignores that snapshot on `.allow`. Almost every hook is allow.

`PacksFacade.effectiveIDs` always `loadIndex()` even when `config.toml` is absent; the result is `dayOnePackIDs`.

### Do

1. `GatedEvaluate.apply` / `peek`:

   ```
   let result = session.evaluate(request)
   switch result.decision {
   case .allow:
       return result          // no allowlist I/O, no store.consume
   case .indeterminate:
       return result          // still no honor (existing law)
   case .deny:
       load allowlist; PolicyGate.apply/peek as today
   }
   ```

   Honor / allow-once / missing-cwd behavior on **deny** is unchanged. Existing `GatedEvaluateTests` stay green.

2. `PacksFacade.effectiveIDs(home:)`:
   - If `home` is empty: keep today’s `PackSet.effectiveOrdered(enabled: [], disabled: [], index:)` (needs index) **or** return `dayOnePackIDs` if and only if that is observably the same set (it is: defaults ∪ ∅ − ∅). Prefer returning `dayOnePackIDs` without I/O when `home` is empty.
   - If `home` is nonempty and `PacksConfigStore.configURL` **does not exist**: return `dayOnePackIDs` without `loadIndex()`.
   - If the file exists: keep today’s load + `effectiveOrdered` (operator may have enabled extras).

3. Tests: deny+grant still honors once; allow evaluate with a **missing** allowlist path does not create the file; `effectiveIDs` with a temp home and no `config.toml` equals `dayOnePackIDs`.

### Do not

- Skip honor on deny.
- Treat indeterminate as allow.
- Change compile policy (T11).
- Persist analytics every evaluate (out of scope unless a one-line “do not await persist on the reply path” comment; do not redesign `AnalyticsCoordinator`).

### Prove

- [ ] allow path: no allowlist file created; existing grant tests still pass
- [ ] deny + grant + cwd still consumes once
- [ ] missing cwd still skips honor
- [ ] `effectiveIDs` without config.toml == `dayOnePackIDs`
- [ ] `effectiveIDs` with an extra pack in config.toml still includes it
- [ ] `tools/gate.sh --quiet RVServiceTests RVCLITests`

## T14 — One-shot evaluate (hello+evaluate)

**Blocked by:** T11 (merge T11 first; exclusive functions in `ServiceRuntime`).

Hook evaluate over XPC is one `perform`, not hello then evaluate.

### Why

Every hook process today: new `NSXPCConnection` → Hello (200 ms budget) → evaluate (500 ms budget). After idle-exit, 200 ms may lose to `rvd` compile-all (T11 shrinks that). A miss then compiles **again** in-process. Combining handshake into the evaluate frame removes one RTT and the “hello timed out, compile twice” trap.

### Do

1. Additive `EvaluateParams` field:

   ```swift
   public var clientSemver: String?  // decodeIfPresent; encode if non-nil
   ```

   Existing clients omit it and still send `Hello` first. That path stays.

2. `ServiceRuntime.handleIncoming`:
   - Existing `Hello` decode path unchanged.
   - If body decodes as `IPCRequest` with `.evaluate(params)` and `handshakeOK == false` and `params.clientSemver != nil`:
     - Build a `Hello(protocolName: request.protocolName, clientSemver: params.clientSemver!)`.
     - `acknowledge(hello)` — same rules (`ok` false on protocol mismatch or core packs unavailable).
     - If `ack.ok == false`: return `IPCResponse` `.error(.protocolSkew(…))` (or existing skew error). Do **not** evaluate on the skewed/unready service. `handshakeOK` stays false.
     - If `ack.ok`: set handshake true and `dispatch` the evaluate as today.
   - If `handshakeOK == false` and the request is evaluate **without** `clientSemver`: keep today’s “handshake required” error (old clients must Hello first).

3. `ServiceClient.evaluate` (XPC path):
   - Do **not** call `transport.hello` first.
   - Encode `EvaluateParams(request:cwd:clientSemver: ProtocolVersion.serviceSemver)`.
   - One `transport.send`.
   - Decode `EvaluateReply` as today. On connect/timeout/interrupt/skew/decode → in-process (existing miss law).
   - `status()` / `diagnostics()` / explain still Hello first (unchanged).

4. Timeouts: the single evaluate `perform` uses **connectTimeoutMs (200) + requestTimeoutMs (500) = 700 ms** as the one budget (or request 700 ms on that send). Document the number in the test name. Do not raise host adapter 5 s.

5. Tests (fake transport / existing Unix-socket test helper):
   - One `perform` for evaluate; `openedConnectionCount` / send count == 1.
   - Skewed implicit hello → in-process deny `git reset --hard`.
   - Down listener → in-process deny.
   - Old shape: Hello then evaluate without `clientSemver` still works.

### Do not

- Bump `rv.ipc.v1`.
- Evaluate against a failed implicit hello.
- Put Unix sockets in production `rvd`.
- Change `hostDenyText`.
- Touch T11 compile functions.

### Prove

- [ ] Hook/XPC evaluate is one send when `clientSemver` is set
- [ ] Down + skew still in-process deny `git reset --hard`
- [ ] `git stash drop` still empty allow on the hook codec
- [ ] Handshake-required still errors if evaluate has no `clientSemver` and no prior Hello
- [ ] `tools/gate.sh --quiet RVIPCTests RVServiceTests RVCLITests`

## Later (fence — no implement prompt)

Not this wave. Do not open a worktree.

| Item | Why it waits |
|---|---|
| **T15 thin hook linkage** | New executable or retargeting `rv` away from TUI/ArgumentParser is a `Package.swift` graph edit. Needs a merge plan in `package-ownership.md`. Hosts still spawn `rv hook`. Do T12 first and measure spawn; only then split the binary. |
| Pack essay sidecar | 333 KB; hooks do not print essays. Changes catalog JSON / T9 load. Parity risk. |
| Analytics debounce / drop CFNetwork from hook | Hook must not phone home already; `rvd` linking PostHog is size, not hook latency. |
| `KeepAlive` | PLAN: not a system daemon. |
| Heredoc / AST | Phase 4+. Latency program of its own. |

## Targets (honest, not gates)

After T10–T14, expect (same machine class, release + strip):

| Artifact / path | Band |
|---|---|
| staged `rv` | ~2.5–3.5 MB + pack bundle ~1 MB beside it |
| staged `rvd` | ~0.9–1.3 MB + same bundle class |
| Warm Grok hook | ~4–8 ms (T12 + T14; spawn still dominates) |
| Cold first hook | well under 5 s; T11 should cut the 62 ms compile-all |

Do not fail a ticket because a number is 1 ms off. Fail if Decision, miss policy, or relocate-evaluate regresses.

## Skills

| Topic | Skill |
|---|---|
| `Package.swift` (must not change) | `.grok/skills/swift-hexagonal-spm` |
| Evaluate / corpus | `.grok/skills/swift-evaluate-parity` |
| Hook / XPC / install | `.grok/skills/swift-hook-xpc` |

Gate: `tools/gate.sh` for the touched `*Tests`. Warm `.build`. Do not wipe `.build`.
