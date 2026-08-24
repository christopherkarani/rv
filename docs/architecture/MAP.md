# rv Architecture Map

> **Source version:** `1.0.0` (`rv.ipc.v1`) — `Package.swift` swift-tools 6.3, Swift 6 language mode, macOS 26 Apple Silicon only.
> **Synthesized:** 2026-08-23 from `Package.swift`, `docs/architecture/MODULES.md`, `docs/dev/SWIFT.md`, `docs/dev/PARITY.md`, `CONTEXT.md`, `docs/factory/PLAN.md`, `Sources/**`, `Sources/rv-c/*`, `Tests/**`, `tools/*` — hand-maintained view, not auto-generated; `docs/architecture/MODULES.md` + `docs/factory/PLAN.md` are arbiters.

## 1. Overview

**rv** is a Mac-native destructive-command guard for coding-agent *shell* hooks. Two binaries:

- `rv` — C hook + Swift operator `rv-cli` (installed as `rv` + `rv-cli` in `$HOME/.local/bin`). Hosts spawn `$HOME/.local/bin/rv hook --host {grok,pi,opencode}`; the C hook pipes `hookEvaluate` to `rvd`, or `exec`s `rv-cli hook` on miss.
- `rvd` — on-demand Mach XPC service `dev.rv.evaluate`, `KeepAlive false`, idle-exit ~300 s. Owns compiled day-one packs and gated evaluation.

**Day-one win:** `git reset --hard` → `deny core.git:reset-hard`. `git stash drop` → `allow` + match (medium). Oversize / missing core → `indeterminate` → host deny without rule_id.
**Hosts v1:** Pi (`~/.pi/agent/extensions/rv-guard.ts`), Grok (`~/.grok/hooks/rv.json`), OpenCode (`~/.config/opencode/plugins/rv-guard.js`). Shell/command tools only; no Read/Edit/MCP hooks. Quiet allow, native deny text. Pi also shows display-only transcript card (`registerMessageRenderer` → `string[]`); OpenCode also shows display-only toast; card/toast never replace `throw`.
**Platform:** macOS 26, Apple Silicon, Swift 6.3.3, `clang -Os` for C. No Linux/Windows/macOS 14/15 claim. Config dir `$HOME/.config/rv/` (`HOME` only, no `XDG_CONFIG_HOME`). Grade is *hook*, not OS-enforced. `RV_BYPASS` is forbidden.

---

## 2. Hexagonal Module Dependency Graph (arrows down)

```
                    ┌──────────┐  ┌──────────┐
                    │ RVDomain │  │ RVTheme  │   ← leaf types, no deps
                    └────┬─────┘  └────┬─────┘
                         │             │
         ┌───────────────┼─────────────┼──────────────────┐
         │               │             │                  │
   ┌─────▼────┐   ┌──────▼─────┐ ┌───▼──────┐ ┌────▼─────┐ ┌───▼────┐ ┌──────────┐ ┌──────────┐
   │ RVEngine │   │  RVPacks   │ │ RVPolicy │ │ RVHooks  │ │ RVIPC  │ │RVHistory │ │RVAnalytics│
   │(RVDomain)│   │ (RVDomain) │ │(RVDomain)│ │(RVDomain)│ │(RVDomain)│ │(RVDomain)│ │ (none)   │
   └────┬─────┘   └──────┬─────┘ └────┬─────┘ └────┬─────┘ └───┬────┘ └────┬─────┘ └────┬─────┘
        │                │            │            │          │           │            │
        └────────────────┼────────────┼────────────┼──────────┼───────────┘            │
                         │            │            │          │                        │
              ┌──────────▼────────────▼────────────▼──────────▼────────────┐          │
              │                    RVService (XPC edge)                     │◄─────────┘
              │  RVDomain + RVEngine + RVPacks + RVPolicy + RVHooks +      │
              │  RVIPC + RVHistory + RVAnalytics                             │
              └──────────────────────────┬─────────────────────────────────┘
                                         │
              ┌──────────────────────────┼──────────────────────────────────┐
              │        RVPresentation (RVDomain + RVTheme)                  │
              └──────────────────────────┬──────────────────────────────────┘
                                         │
              ┌──────────────────────────▼──────────────────────────────────┐
              │              RVTUI (RVTheme + RVPresentation)               │
              └──────────────────────────┬──────────────────────────────────┘
                                         │
              ┌──────────────────────────▼──────────────────────────────────┐
              │  RVCLI (thin client — all above + ArgumentParser)           │
              │  RVDomain, RVEngine, RVPolicy, RVHooks, RVIPC,              │
              │  RVPresentation, RVTheme, RVTUI, RVService, RVHistory,      │
              │  RVAnalytics                                                  │
              └──────────┬──────────────────────────────┬─────────────────────┘
                         │                              │
              ┌──────────▼──────┐            ┌──────────▼──────┐
              │  rv (Swift)     │            │  rvd (Swift)    │
              │  executable     │            │  executable     │
              │  → RVCLI        │            │  → RVService    │
              └─────────────────┘            └─────────────────┘

  ┌──────────┐  outside SPM
  │  rv-c    │  C hook: rv.c + json_escape + json_reply (libSystem + XPC only)
  └────┬─────┘  no Swift deps; installed as `rv`, sibling `rv-cli`, `rvd`
       │ pipe: rv.ipc.v1 hookEvaluate → dev.rv.evaluate
       └─────────────────────────────────────────────► RVService
```

**Law:** Engine never imports CLI, TUI, XPC. Hooks never imports Service/CLI. Presentation never emits ANSI. TUI never opens a TTY (`render(width) → [String]`). A test needing a TTY to prove a **Decision** is in the wrong module.

---

## 3. Per-Module Catalog

| Module | Purpose | Key Types / Files | Dependencies | Must NOT |
|---|---|---|---|---|
| **RVDomain** | Closed type system: decisions, requests, results, packs. Pure value types, `Sendable`. | `Decision` (`allow`/`deny(Deny)`/`indeterminate`), `Deny`, `IndeterminateReason`, `Severity`, `PackID` (`^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)?$`), `RuleID` (`pack:pattern`, display `pack/pattern`), `ShellCommand`, `EvaluationRequest/Result`, `EvaluationOutcome`, `MatchingView`, `PackSnapshot`, `ExplainStep`, `Display` · `RVDomain.swift`, `Decision.swift`, `Severity.swift`, `PackID.swift`, `RuleID.swift`, `ShellCommand.swift`, `EvaluationRequest.swift`, `EvaluationResult.swift`, `ExplainStep.swift`, `PackSnapshot.swift`, `Display.swift`, `MatchingView.swift`, `Coding.swift` | none | I/O, TTY, XPC, `Date`/`FileManager` |
| **RVEngine** | Functional core `evaluate`. Pure, budgeted, deadline-aware. | `evaluate(_:packs:patterns:compiled:)`, `Normalize.matchingView(of:)`, `QuickReject`, `CompiledPacks`, `PatternEngine`/`ICUPatternEngine`, `commandByteCap=65536`, `isMajorSkew` · `Evaluate.swift`, `Normalize.swift` (role-aware quote strip, wrapper unwrap `sudo/env/command/\\`), `QuickReject.swift`, `ICUPatternEngine.swift`, `PatternEngine.swift`, `CompiledPacks.swift`, `RVEngine.swift` | `RVDomain` | pack files, hooks, XPC, CLI, TUI |
| **RVPacks** | Registry + bundled JSON catalog (99 packs, 27 categories). Disabled by default except day-one. | `PackRegistry.loadAll/loadDayOne/loadIndex`, `PackCatalog`, `PackIndex`, `PackJSON`, `PackEnablement`, `SelectionToken`, `PackDocument` · `RVPacks.swift`, `PackRegistry.swift`, `PackCatalog.swift`, `PackIndex.swift`, `PackJSON.swift`, `PackEnablement.swift`, `SelectionToken.swift` · `Resources/packs/*.json` (`core.git`, `core.filesystem` day-one + 97 off) | `RVDomain` | decisions, rendering |
| **RVPolicy** | Config merge + overrides: allowlist + single-use allow-once grants. | `PolicyGate.{peek,apply}`, `PolicyDecision/Override`, `AllowOnceStore` (atomic CAS), `AllowOnceRecord`, `Allowlist/AllowlistStore`, `PacksConfig`, `HomeDirectory`, `ExclusiveFileLock` · `PolicyGate.swift`, `AllowOnceStore.swift`, `AllowOnceRecord.swift`, `Allowlist.swift`, `PacksConfig.swift`, `RVPolicyPaths.swift` | `RVDomain` | rendering |
| **RVHooks** | Pi / Grok / OpenCode **Host adapters**: codecs, HostAdapterResources, Hook mapper/voice. | `HostCodec` protocol, `GrokHostCodec` (`pre_tool_use` + `run_terminal_command`/`run_terminal_cmd`/`Bash`), `PiHostCodec`, `OpenCodeHostCodec`, `HookMapper.hookWire(from:command:using:)`, `HostDenyText`, `HookDecode`, `HookDenyJSON`, `HostAdapterResources` (embed `__RV_BINARY__` → baked `rv` path) · `HostCodec.swift`, `GrokHostCodec.swift`, `PiHostCodec.swift`, `OpenCodeHostCodec.swift`, `HookMapper.swift`, `HostDenyText.swift`, `HostAdapterResources.swift` | `RVDomain` | evaluation, setup mutations, CLI/TUI |
| **RVIPC** | `rv.ipc.v1` Codable envelope + frame codec. | `IPCRequest/Response`, `IPCMethod`/`IPCResult` (`evaluate`, `hookEvaluate`, `explain`, `classify`, `listPacks`, `setPackEnabled`, `allowOnceConsume`, `doctorSnapshot`), `EvaluateParams/Reply`, `HookEvaluateParams/Reply`, `ExplainParams/Reply`, `ClassifyParams/Reply`, `DoctorSnapshotReply`, `Hello/HelloAck`, `ProtocolVersion` (`1.0.0`, `isMajorSkew`), `FrameCodec` (u32 BE len + 1 MiB cap), `SkewReason` · `IPCEnvelope.swift`, `IPCMethods.swift`, `ProtocolVersion.swift`, `FrameCodec.swift`, `IPCJSON.swift` | `RVDomain` | transport details |
| **RVService** | XPC listener + warm evaluate runtime + launchd. Only `class`/`NSObject` edge. | `EvaluateSession` (CoreWarmup, compiled day-one, `corePacksReady`), `GatedEvaluate` (peek vs apply + PolicyGate), `ServiceRuntime` (`handleIncoming`, `dispatch`, `HookDoor.run`, `doctorSnapshot`, `recordAnalytics`), `HookDoor`, `XPCListener/XPCPeerSession` (`xpc_data` key `rv.ipc`), `RVDLaunch/RVDProcess`, `IdleExit`, `PacksFacade`, `EnabledPacks`, `DoctorSnapshotBuilder`, `ServiceFrames`, `XPCEvaluateClient` · `RVService.swift`, `EvaluateSession.swift`, `GatedEvaluate.swift`, `ServiceRuntime.swift`, `HookDoor.swift`, `XPCListener.swift` | `RVDomain`, `RVEngine`, `RVPacks`, `RVPolicy`, `RVHooks`, `RVIPC`, `RVHistory`, `RVAnalytics` | `ArgumentParser`, SwiftUI, TUI/CLI/Presentation |
| **RVPresentation** | Deny/explain/packs/doctor view models (no ANSI). | `ExplainViewModel`, `TestViewModel`, `DenyViewModel`, `DoctorViewModel`, `PacksViewModel`, `SetupViewModel`, `SetupCeremony/UninstallCeremony`, `RobotPayloads`, `ExplanationLines`, `Suggestions`, `DecisionWord` · `ExplainViewModel.swift`, `TestViewModel.swift`, `DenyViewModel.swift`, `DoctorViewModel.swift`, `PacksViewModel.swift`, `SetupViewModel.swift`, `RobotPayloads.swift` | `RVDomain`, `RVTheme` | ANSI |
| **RVTheme** | Palettes + pure capability detection. No business rules. | `Palette` (`fact/muted/deny/allow/heading/mark/trace/silver`, `RegexInk`), `ColorCapability`, `OutputMode` (`robot`/`pretty`/`browse`), `ThemeProbe` · `Palette.swift`, `ColorCapability.swift`, `OutputMode.swift`, `ThemeProbe.swift` | none | business rules |
| **RVTUI** | Browse kit `reduce + render → [String]`, key map. | `BrowseState`, `Render.browseFrame/render`, `Reduce`, `KeyMap`, `ExplainRenderer`, `TestRenderer`, `PacksRenderer`, `DoctorRenderer`, `SetupRenderer`, `FrameRenderer`, `RegexPaint`, `TreeLines` · `RVTUI.swift`, `Render.swift`, `Reduce.swift`, `BrowseState.swift`, `KeyMap.swift` | `RVTheme`, `RVPresentation` | opening a TTY |
| **RVCLI** | ArgumentParser tree, output mode, thin XPC client, setup/uninstall state machine, TTY path. | `RV` (`@main` ParsableCommand), `Commands/{Test,Explain,Packs,Doctor,Setup,Uninstall,Hook,Service}`, `CommandInvocation/CommandRun`, `Hook/HookDispatch`, `Service/{ServiceClient,XPCClient,ServiceHealth,ServiceDiagnostics}`, `Setup/{SetupRun,HostAdapterInstallation,LaunchAgentTemplate,OwnedPaths}`, `Doctor/DoctorRun`, `Help/HelpDispatch`, `RobotDocument`, `PrettyWriter` · `RVCLI.swift`, `RV.swift`, `Commands/*.swift` | `RVDomain`, `RVEngine`, `RVPolicy`, `RVHooks`, `RVIPC`, `RVPresentation`, `RVTheme`, `RVTUI`, `RVService`, `RVHistory`, `RVAnalytics`, `ArgumentParser` | regex, pack JSON parse (packs are data) |
| **RVHistory** | **Stub** — history off by default, never logs full argv/paths. | `RVHistory` enum stub · `RVHistory.swift` | `RVDomain` | logging full argv, `os_log` command text |
| **RVAnalytics** | Anonymous product analytics (PostHog), opt-out via `analytics.enabled` in `~/.config/rv/config.json`. Never host hook process. | `AnalyticsCoordinator` (`recordDecision`, `flushDailyIfNeeded`), `AnalyticsIdentity/Sink/Paths/Preferences`, `PostHogSink`, `AnalyticsNotice` · `AnalyticsCoordinator.swift`, `RVAnalytics.swift` | none (actor ok) | command text/paths/secrets; hook-process I/O; network in non-sink |
| **rv** (exec) | Swift operator entry. Help fast-path + hook fast-path → `RV`. | `Sources/rv/main.swift` → `HelpDispatch` → `HookDispatch` → `RV.main()` | `RVCLI` | — |
| **rvd** (exec) | XPC daemon entry. | `Sources/rvd/main.swift` → `RVDLaunch` → `RVDProcess` | `RVService` | — |
| **rv-c** (C) | Installed `rv` binary. Pipes `hookEvaluate`, execs `rv-cli`. | `rv.c`, `json_escape.{c,h}`, `json_reply.{c,h}`, `tests/{json_escape_test,json_reply_test}.c` | libSystem + `xpc.h` + `dispatch` | Foundation, CFNetwork, ArgumentParser, ICU, decision logic |

---

## 4. Data-Flow Diagrams

### (a) Evaluate Pipeline (`RVEngine.evaluate`)

```
ShellCommand.rawValue (e.g. `"  \"git\" reset --hard "`)
        │
        ▼  1. Guard: whitespace-only? → plain allow
        │   Guard: utf8 > 65536 ? → indeterminate .commandTooLarge
        │   Guard: !corePacksAreReady (core.git + core.filesystem present &
        │           reset-hard + fork-bomb compiled) ? → indeterminate .corePacksUnavailable
        │
        ▼  2. Normalize.matchingView(of:)   ──────────────────────────┐
   applyRoleAwareQuotes:                                            │ tokenizeCommand
     • strip quotes on argv0/flags only                             │ role-aware:
     • mask data-role args (git -m "...", echo/printf all, rg/grep)│  sudo/env/command wrappers
     • keep separators, inline `$(…)` / ```` as code                 │  quote stripping, flag masking
   then iterative unwrap: sudo → env (assignments/flags) → command  │
                          → leading `\` (≤32 iters)                  │
   then stripAbsolutePathOnArgv0: /usr/bin/git → git                 │
        │                                                            │
        ▼  3. QuickReject.shouldSkip? ──yes──► EvaluationResult        │
        │     skip if no enabled-pack keyword hits AND no            │ quickRejected
        │     force-filesystem empty-paren `:(){` shape               │ (allow)
        │     no ──► walk packs                                        │
        ▼  4. Budget + segment split                                   │
   splitSegments(matchingView) on &&, ||, ;, | respecting quotes      │
   for each segment (and then whole view):                            │
        │                                                            │
        ▼  5. evaluateSingle(view, compiledEnabled, patterns)           │
     for pack in compiled (keywordHit || forceFilesystem filter):      │
       safe walker first ──► if ICUPatternEngine.matches(hit)          │
                              lastSafe = SafeMatch; break; continue pack│ (skip destructive)
       destructive walker ──► for rule in pack.destructive:            │
                              attempts++ ; budget? → indeterminate     │
                              firstMatch(compiled, in: view) ─►        │
                               severity.blocksByDefault?               │
                                 yes → deny(Deny(ruleID,reason),match)│ (critical/high)
                                 no  → remember hit (medium/low)      │
     remembered? → hit(remembered, safe:lastSafe) (allow+match)       │
     lastSafe?   → safeOnly(lastSafe) (allow)                         │
     else        → nil → plain allow                                  │
        │                                                            │
        ▼  6. Attach MatchingView, isTerminal? (deny/indeterminate   │
              terminal per segment) else plain                        │
        │                                                            │
        ▼                                                         ────┘
EvaluationResult { outcome, matchingView }
  plain | quickRejected | safeOnly | hit | deny | indeterminate
  matchedSafe / matched carried for explain/classify
```

Order guarantee per `docs/dev/PARITY.md`: `normalize → quick-reject → safe → destructive → default allow`. Safe runs before destructive so exits-early if safe matches.

### (b) Hook Request Flow (host adapter → C hook → rvd → mapper → host wire)

```
Host (Grok / Pi / OpenCode)
  │ spawns  $HOME/.local/bin/rv hook --host {grok,pi,opencode}
  │ stdin = raw host JSON (Grok pre_tool_use + tool_input.command, Pi tool event, OC plugin payload)
  ▼
rv (C) — Sources/rv-c/rv.c — 36 KB stripped
  │ parse_hook_argv: --host/--host=, default grok, invalid→ exec rv-cli, -h/--help→ exec rv-cli
  │ buf_read_fd(STDIN, 1 MiB cap, NUL check, utf8 check)
  │  oversize / NUL / !utf8_valid → miss_replay
  │ build_request: uuid + rv_json_escape(stdin) + __RV_BINARY__ JSON envelope
  │  {id, method:{hookEvaluate:{clientSemver:"1.0.0", host, stdin}}, protocol:"rv.ipc.v1"}
  │ xpc_hook_evaluate: xpc_connection_create_mach_service(dev.rv.evaluate)
  │  signal(SIGPIPE, SIG_IGN); dispatch_semaphore 700 ms (200 connect + 500 request)
  │  xpc_dictionary_set_data(key rv.ipc, json, len)
  │  ├─ success (≤700 ms) ─► rv_parse_hook_reply(JSON) via json_reply.c
  │  │     check has_service_semver && !isMajorSkew("1.0.0", serviceSemver)
  │  │     ├─ ok → write_all(stdout_bytes, exitCode) → exit(exitCode)
  │  │     └─ skew/missing → miss_replay
  │  └─ timeout / XPC_TYPE_ERROR / !XPC_TYPE_DICTIONARY / missing rv.ipc → miss_replay
  │
  │ miss_replay (only path that may fork):
  │  find_rv_cli: realpath(argv0)/rv-cli else $HOME/.local/bin/rv-cli; missing → last_resort _exit(2) (Grok empty+0 is allow; ≠2 must not look like allow)
  │  pipe(in)+pipe(out), fork, child dup2(stdin/out) + execve(rv-cli, ["rv-cli","hook","--host",host])
  │  parent write_all(stdin) → read out → waitpid → write stdout → _exit(status)
  │  operator non-hook argv always execve(rv-cli) with same argv/env/cwd
  │
  ▼ (pipe path only)
rvd — ServiceRuntime + XPCListener (dev.rv.evaluate)
  │ XPCPeerSession.handle: XPCIPCWire.body = xpc_dictionary_get_data(rv.ipc)
  │  handleIncoming(body, handshakeOK):
  │   try Hello decode → acknowledge(protocol, majorSkew, corePacksReady)
  │   else if !handshakeOK → handleUnreadyIncoming: decode IPCRequest, implicitHelloSemver(evaluate|hookEvaluate)
  │   else dispatch(IPCRequest)
  │ dispatch case .hookEvaluate(params):
  │   isMajorSkewed(clientSemver)? → .error(.protocolSkew)
  │   HookDoor.run(host, stdin) { command, cwd in
  │     GatedEvaluate.makeRequest(command, home: configHome) → EvaluationRequest(enabledPacks=resolve)
  │     gated.apply(request, cwd, store: AllowOnceStore.live(), now)
  │   }
  │
  │  HookDoor internals:
  │   GrokHostCodec / PiHostCodec / OpenCodeHostCodec
  │     decode(stdin) → .request(HookRequest{command,cwd}) | .foreign | .malformed
  │     foreign/malformed → encodeAllow() (empty stdout, exit 0)
  │     else GatedEvaluate → EvaluationResult → HookMapper
  │
  │  GatedEvaluate (EvaluateSession + PolicyGate):
  │   session.evaluate(request) → EvaluationResult (day-one + EnabledPacks.resolve extras)
  │   if allow|indeterminate → return result
  │   if deny → AllowlistSnapshot.matches(ruleID, matchingView) ? allow(hit, allowlist)
  │            else if cwd empty / matchingView empty → deny
  │            else AllowOnceStore.consume(matchingView,cwd) atomically → allow or deny
  │
  │  HookMapper.hookWire(from:result, command, codec):
  │   allow → codec.encodeAllow()
  │   deny(Deny) → codec.encodeDeny(reason: hostDenyLine(cmd, ruleID), rule: displayRuleID, next: "Run it in Terminal, or rv allow-once.")
  │   indeterminate → codec.encodeDeny(reason: "rv could not finish evaluating this command. Run it in Terminal.", rule:nil)
  │   HostCodec.encodeDeny → HookWire(stdout: hookDenyJSON(reason,rule,next)+"\n", exitCode: host.denyExitCode)
  │     grok=0 (JSON is gate, empty+0 is allow), pi=1, opencode=1
  │
  ▼ reply
  HookEvaluateReply { stdout, exitCode, via:"xpc", serviceSemver:"1.0.0" }
  │ IPCResponse { id, protocol:"rv.ipc.v1", result:{hookEvaluate: reply} } → IPCJSON.encode → xpc_dictionary_set_data(rv.ipc)
  │ xpc_connection_send_message(peer, reply)
  ▼
rv (C) writes stdout + exitCode (or miss_replay produced same via rv-cli → ServiceClient one-shot evaluate → same codecs)
Host interprets:
  Grok: {"decision":"deny","reason":"<hostDenyText>"} exit 0 → block; empty exit 0 → allow; exit 2 fallback deny (last_resort)
  Pi:    JSON hookDeny → block; empty → allow (extension throws)
  OpenCode: same JSON via plugin; rv-cli miss throws + toast attempted before throw
```

Skew/miss invariants: down / major skew / `serviceSemver` nil → never allow; C replays through Swift in-process evaluate; `indeterminate` never consumes a grant; `_exit(2)` on C miss-without-sibling never looks like allow.

### (c) TTY test / explain Flow (never asks rvd)

```
Terminal: rv test "git reset --hard"          rv explain --robot "rm -rf /"
        │ rv test --explain …                  │ rv test --json … (robot)
        ▼                                      ▼
HelpDispatch.tryEmit(args)? ─yes─► print help, exit 0 (no evaluate)
        │ no
HookDispatch.matches(["hook",…])? ─yes─► Hook.run() via ServiceClient (XPC or GatedEvaluate fallback)
        │ no
RV.main() (ArgumentParser)
  Test / Explain command → CommandInvocation.emit(kind, commandParts, format)
    ThemeProbeFactory.live(json,robot,plain,noColor → isTTY, CI, NO_COLOR, --robot/--json)
    OutputModeResolver.requested → RequestedMode → OutputMode(probe, requested)
      robot if --json/--robot else pretty if TTY else plain; browse only if both stdin+stdout TTY
    CommandRun.run(kind, command: rawJoined, probe, requested, cwd: FileHandle cwd, store: .live())
      → evaluateCommand(raw, cwd, store, home)  // GatedEvaluate peek (no grant consume)
          EvaluateSession()                      // warm CoreWarmup: loadAll() or loadDayOne(), enabled=EnabledPacks.resolve(home)+dayOne
            → callEngineEvaluate(request, packs, ICUPatternEngine, compiled)
          → PolicyGate.peek(result, cwd, allowlistSnapshot, store, now) // show grant without spending
      → render(kind, result, command, probe, requested)
          mode == .robot?
            yes → RobotDocument.test/explain(...).render() + "\n", exit 0 if explain else 1 if deny
            no  → palette = Palette(for: ColorCapability(probe, mode))
                  kind.usesExplainFrame?
                    yes → explainViewModel(from: result, command, normalized=matchingView) → ExplainRenderer.render(viewModel, palette)
                    no  → testViewModel(from: result, command, columns) → TestRenderer.render(model, palette)
                  → PrettyWriter.join(lines) + "\n", exit 0 if explain else 1 if deny
    FileHandle.stdout.write(...); throw ExitCode(code)
```

Explain pipeline ↔ IPC `ExplainStage`: `explainSteps(from:)` maps `EvaluationOutcome` → `[ExplainStep]` (`normalize→quick-reject→safe→destructive→default`); `elapsedMs` always 0; robot `rv.explain.v1` / `rv.test.v1` share same steps. TTY never touches `rvd`; XPC `explain`/`classify` reuse `GatedEvaluate.peek` on daemon side.

---

## 5. File Tree

```
rv/
├── Package.swift                     # 13 libs + rv + rvd, swift-tools 6.3, macOS 26, SPM bundle for packs
├── .swift-version                   # 6.3.3 pin (tools/swift-6.3.3 preferred)
├── README.md / AGENTS.md / CONTEXT.md
├── spec/spec-architecture-c-hook-pipe.md  # T1–T5 C hook pipe spec (supersedes T15 thin Swift)
├── vendor/parity/PIN                # pinned 0.11.0 tag 6d4fcaef… commit 2ed7eeef…
├── install.sh                       # curl entry: copies rv, rv-cli, rvd + bundles → ~/.local/bin, execs rv setup
├── Resources/launchd/dev.rv.evaluate.plist  # KeepAlive false, RunAtLoad false
├── Sources/
│   ├── rv-c/                        # C hook (not SPM): rv.c, json_escape.{c,h}, json_reply.{c,h}, tests/
│   ├── RVDomain/                    # Decision.swift, Severity.swift, PackID.swift, RuleID.swift, etc. (13 files)
│   ├── RVTheme/                     # Palette.swift, ColorCapability.swift, OutputMode.swift, ThemeProbe.swift
│   ├── RVEngine/                    # Evaluate.swift, Normalize.swift, QuickReject.swift, CompiledPacks.swift, ICUPatternEngine.swift, PatternEngine.swift, RVEngine.swift (7 files)
│   ├── RVPacks/                     # PackRegistry.swift, PackCatalog.swift, PackIndex.swift, PackJSON.swift, PackEnablement.swift
│   │   └── Resources/packs/         # 99 JSON packs + index.json (rv_RVPacks.bundle at runtime)
│   ├── RVPolicy/                    # PolicyGate.swift, AllowOnceStore.swift, Allowlist*.swift, PacksConfig.swift
│   ├── RVHooks/                     # HostCodec.swift, Grok/Pi/OpenCodeHostCodec.swift, HookMapper.swift, HostAdapterResources.swift
│   │   └── Resources/hosts/         # embedded templates: rv_json_tmpl, rv_guard_ts_tmpl, rv_guard_js_tmpl (embedInCode)
│   ├── RVIPC/                       # IPCEnvelope.swift, IPCMethods.swift, ProtocolVersion.swift, FrameCodec.swift, IPCJSON.swift, SkewReason.swift
│   ├── RVService/                   # EvaluateSession.swift, GatedEvaluate.swift, ServiceRuntime.swift, HookDoor.swift, XPCListener.swift, IdleExit.swift, RVDLaunch.swift, DoctorSnapshotBuilder.swift, …
│   ├── RVPresentation/              # ExplainViewModel.swift, TestViewModel.swift, DenyViewModel.swift, DoctorViewModel.swift, …
│   ├── RVTUI/                       # Render.swift, Reduce.swift, BrowseState.swift, KeyMap.swift, ExplainRenderer.swift, …
│   ├── RVCLI/                       # RV.swift, CommandRun.swift, Commands/*, Hook/HookDispatch.swift, Service/*, Setup/*, Doctor/*, Help/*
│   │   └── Resources/launchd/       # dev.rv.evaluate.plist template (embedInCode)
│   ├── RVHistory/                   # RVHistory.swift (stub)
│   ├── RVAnalytics/                 # AnalyticsCoordinator.swift, AnalyticsSink.swift, AnalyticsPaths.swift, …
│   ├── rv/main.swift                # @main RVEntry: HelpDispatch → HookDispatch → RV.main()
│   └── rvd/main.swift               # @main RVD: RVDLaunch.parse → RVDProcess.run
├── Tests/
│   ├── RVDomainTests/ / RVEngineTests/ (Fixtures/corpus/) / RVPacksTests/ / RVPolicyTests/
│   ├── RVHooksTests/ (Fixtures/{grok,pi,opencode,adapters}/)
│   ├── RVIPCTests/ / RVServiceTests/ (Support/UnixFrameChannel) / RVPresentationTests/
│   ├── RVThemeTests/ / RVTUITests/ / RVCLITests/ / RVHistoryTests/ / RVAnalyticsTests/
│   └── RVCorpusTests/ (corpus agree)
├── tools/
│   ├── gate.sh                      # preflight + swift-6.3.3 test --filter inference (never full suite by default)
│   ├── preflight.sh / swift-6.3.3 / c-hook-proof.sh / release.sh / worktree-cleanup.sh
│   └── README.md
├── docs/
│   ├── architecture/MODULES.md      # owns/must-not + dependency table
│   ├── architecture/MAP.md          # ← this file
│   ├── dev/SWIFT.md                 # compile times, style contract, artifact sizes
│   ├── dev/PARITY.md                # upstream 0.11.0 scoreboard, catalog drift table
│   └── factory/{PLAN.md,STATUS.md,specs/,prompts/,reviews/}
└── .build/                          # warm ModuleCache (~80 MB Darwin/Foundation), do not wipe to prove compile
```

Artifact sizes (2026-08-21 `tools/release.sh`, `strip -x`): `rv` 36 KB C, `rv-cli` 2.3 MB, `rvd` 886 KB, `rv_RVPacks.bundle` 1.0 MB.

---

## 6. C Hook Layer (`Sources/rv-c/`)

| File | Owns | Notes |
|---|---|---|
| `rv.c` | `main` pipe/miss router, `ByteBuf` (grow 4 KiB doubling, NUL scan), `parse_hook_argv`, `find_rv_cli` (realpath argv0 dir + `$HOME/.local/bin/rv-cli`), `miss_replay` (pipe pair + fork + `execve` + `waitpid`), `build_request` (`rv_json_escape` + uuid), `xpc_hook_evaluate` (700 ms `dispatch_semaphore`, `rv.ipc` `xpc_data`), `is_major_skew` (major int compare, bad → not skew) | `RV_MACH_SERVICE=dev.rv.evaluate`, `RV_IPC_KEY=rv.ipc`, `RV_CLIENT_SEMVER=1.0.0`, `RV_STDIN_XPC_MAX=1 MiB`. `SIGPIPE` ignored so EPIPE → `write_all` fail → `last_resort` deny. Timeout leaks `XpcWait` until exit (commented race avoidance). |
| `json_escape.h` / `json_escape.c` | UTF-8 validation + JSON string escape/unescape | `rv_utf8_is_valid` (overlong/surrogate/0x10FFFF checks), `rv_json_escaped_len`, `rv_json_escape` (\" \\ \b \f \n \r \t, else `\u00xx` for `<0x20`), `rv_json_unescape` (surrogate pair → utf8). `json_escape_test.c` + `run.sh`. |
| `json_reply.h` / `json_reply.c` | Minimal JSON parser for `IPCResponse.result.hookEvaluate` | Hand-rolled `Cur` with `skip_ws`, `peek/eat`, `skip_string_raw`, `parse_string` (unescape), `skip_value/object/array/number/literal`, `parse_int32`, `next_object_key`. `parse_hook_evaluate` requires `stdout:string`, `exitCode:int32`, `via=="xpc"`, optional `serviceSemver:?string`, `RV_JSON_MAX_DEPTH=64`. Top-level requires `protocol=="rv.ipc.v1"` + `result.hookEvaluate`. Anything else → `RV_HOOK_REPLY_MISS` → miss. `json_reply_test.c`. |

Build: `clang -Os` + `strip -x`, `otool -L` must not list Foundation/CFNetwork/Swift. `Sources/rv-c/tests/run.sh` builds tiny test bins (no `lit`).

---

## 7. IPC + Service Layer (`rv.ipc.v1`)

**Wire:** Mach XPC `dev.rv.evaluate`, `xpc_dictionary` key `rv.ipc` carrying UTF-8 JSON bytes (`IPCJSON`). Tests use Unix `FrameCodec` (4-byte BE len prefix, max 1 MiB). No `--socket` in production `rvd`.

**Envelope:**
- Client hello (edge): `Hello { protocol:"rv.ipc.v1", clientSemver:"1.0.0" }` → `HelloAck { protocol, serviceSemver, ok, skewReason? }`. `acknowledge` checks protocol, `ProtocolVersion.isMajorSkew`, `corePacksReady`.
- One-shot: `IPCRequest { id:UUID, protocol, method }` + `clientSemver` on `evaluate`/`hookEvaluate` for implicit hello. Unready → `handleUnreadyIncoming` → if `clientSemver` present → `acknowledge` → `ok? dispatch : error(protocolSkew "handshake required")`. Per-method major-skew check even after handshake.
- `IPCMethod`: `evaluate(EvaluateParams{request,cwd,clientSemver?})`, `hookEvaluate(HookEvaluateParams{host,stdin,clientSemver?})`, `explain`, `classify`, `listPacks`, `setPackEnabled`, `allowOnceConsume` (stub → error), `doctorSnapshot`.
- `IPCResult`: mirror + `error(IPCError)`, `EvaluateReply{result, via:"xpc", serviceSemver}`, `HookEvaluateReply{stdout, exitCode, via, serviceSemver}`, `ExplainReply{result,normalized,ruleID,packID,suggestion,stages}`, `ClassifyReply`, `ListPacksReply`, `DoctorSnapshotReply`.

**ServiceRuntime** (`ServiceRuntime.swift` 488 lines):
- `init(snapshots?, catalog?, home, allowOnce?, idleExitSeconds, log, analytics)`: builds `PackCatalog` via `PacksFacade`, snapshots via `PackRegistry`, `CoreWarmup.prepare` → `CompiledPacks` (quarantine non-compiling pattern, never quarantine reset-hard/fork-bomb), `GatedEvaluate`, `AllowOnceStore.live()`.
- `acknowledge`, `handleIncoming(body, handshakeOK)`, `dispatch(IPCRequest)` (logs `ServiceLogEvent` without command text), `makeEvaluateReply`, `makeHookEvaluateResult` (→ `HookDoor.run` with `GatedEvaluate.makeRequest`), `explain/classify` (both `gated.peek`), `listPacks`, `setPackEnabled` (enable/disable via `PacksFacade`, rebuild gated, analytics note), `doctorSnapshot`, `recordAnalytics(kind)` (→ `AnalyticsCoordinator`).

**XPCListener** (`XPCListener.swift`): `xpc_connection_create_mach_service(listener)`, `handleListenerEvent` → `accept(peer)` → `XPCPeerSession(runtime)` with `handshakeOK` lock + `XPCHeld` retained across `Task { handleIncoming }`, reply via `xpc_dictionary_create_reply` + `xpc_connection_send_message`.

**Health:** `RVCLI/ServiceClient.swift` `ServiceClient.route()` → `hello` → `skewReason` → `xpc`/`down`/`skew`/`failed`; `status()` → `ServiceHealth.inspect(diagnostics()).statusReport`; `evaluate` → `IPCRequest(evaluate)`  → require `via=="xpc"` + `serviceSemver` present + not major skew else `invalidate` + in-process `GatedEvaluate.apply` fallback. Same law in C hook.

---

## 8. Cross-Cutting Concerns

**Parity — upstream 0.11.0** (`docs/dev/PARITY.md`): Tag `v0.11.0` `6d4fcaef…` commit `2ed7eeef…`, pin `vendor/parity/PIN`. Scoreboard is 0.11.0 *engine source* (critical/high deny, medium/low allow+match). `rm -rf ${TMPDIR}/build` stays deny `rm-rf-general`; `git stash drop` allow; `git restore --worktree` vs `-W/-S` naming; `rm -rf /var/log` → `rm-rf-root-home`; `fork-bomb` empty-paren force-scan. `rv test` vs upstream agree rate is long-term, not v1 gate.

**Catalog:** 99 IDs / 27 categories extracted via `tools/extract-packs --source-root` into `Resources/packs/*.json`. Day-one compiled = `{core.filesystem, core.git}` only; `system.disk` and Windows packs exist in bundle but off until `rv packs enable`. `rv packs` mutates `$HOME/.config/rv/config.toml` `[packs]`; `listPacks` + `PacksFacade` + `rebuildWhenUncovered(wanted:)` self-heal (at-most 1/s).

**Analytics (`RVAnalytics`):** Actor `AnalyticsCoordinator` + `AnalyticsPreferences` (opt-out `analytics.enabled` in `config.json`, missing = on) + `AnalyticsIdentity` (stable distinctID) + `AnalyticsPaths` (`~/.config/rv/`) + sinks `PostHogSink`/`NoOpAnalyticsSink` + `PlatformSnapshot`. Captures `install` once + `daily_active` at-most daily (allow/deny/indeterminate counts, enabled pack IDs, host statuses). Never command text/paths/secrets; host hook processes never call it. `tools` + `install.sh` trigger `captureInstall` only.

**History (`RVHistory`):** Stub enum, off by default forever until a later ticket. `RVService` depends on it but never writes; `ServiceLog` records only method/decision/ruleID/elapsed/requestID, never command.

**Safety laws (from `docs/factory/PLAN.md`):**
- Down/skew never becomes allow (in-process evaluate). Indeterminate → host deny sentence without rule_id.
- `hostDenyText` canonical: `Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once.`; incomplete: `rv could not finish evaluating this command. Run it in Terminal.`
- No `RV_BYPASS`, no host Allow UI, no foreign hook writes, no live-HOME tests, no `os_log` command text, no Seatbelt/OS-enforced claim, no Homebrew in v1.

**Performance / Toolchain:** `tools/swift-6.3.3` wrapper; `tools/gate.sh` infers `*Tests` from git diff; `tools/preflight.sh` checks hygiene (no forbidden tokens outside `docs/factory/`, Swift 6 mode). `.build` warm ~80 MB ModuleCache; `swift package clean` wipes it (slow cold ~12 s). Slowest body `tokenizeCommand` ~22 ms.

---

## 9. Quick Reference

**Install / Run:**
```sh
RV_INSTALL_BIN=/path/to/staged ./install.sh   # → ~/.local/bin/{rv,rv-cli,rvd} + bundle
rv setup            # bake adapters, write LaunchAgent (KeepAlive false)
rv doctor --robot   # rv.doctor.v1 JSON
rv test "git reset --hard"           # peek, deny exit 1, explain frame
rv explain "rm -rf /" --robot        # rv.explain.v1 JSON
rv packs list / enable core.git
rv allow-once "Blocked …"            # TTY only, spends {matchingView,cwd} grant (atomic CAS)
```

**Verify:**
```sh
tools/gate.sh --quiet RVIPCTests RVServiceTests RVCLITests RVHooksTests
otool -L ~/.local/bin/rv | grep -v Foundation
/dev/null; printf '%s' '{"hookEventName":"pre_tool_use","toolName":"run_terminal_command","toolInput":{"command":"git reset --hard"}}' \
  | ~/.local/bin/rv hook --host grok | jq .
```

> This map is a *view* — `docs/architecture/MODULES.md` and `docs/factory/PLAN.md` remain conflict arbiters.
