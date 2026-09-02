# rv

Mac-native destructive-command guard for coding-agent shell hooks. Day-one hosts: Pi, Grok, OpenCode. Also: Claude (settings merge), OpenClaw (`~/.openclaw/extensions/rv-guard/`, host only, no Ask), Hermes (`~/.hermes/plugins/rv-guard/`, host only, no Ask), Codex (`~/.codex/hooks/rv-guard.py`, host only, official `block` + stderr reason + exit 2, no Ask), and Cursor (`~/.cursor/hooks/rv-guard.py`, host only, official `permission: deny` + exit 0, no Ask).

## Language

**CLI surface**:
`rv`. Humans type `rv <subcommand>`. Hosts spawn `rv hook`. There is no second command.
_Avoid_: rv-cli as a product, “the Swift CLI”, listing rv-cli next to rv and rvd as three tools

**Hook client**:
The C program installed at `$HOME/.local/bin/rv`. Pipes `hookEvaluate` to rvd. Non-hook argv and XPC miss exec the operator.
_Avoid_: C matcher, C evaluator

**Operator**:
The Swift binary that implements test/setup/doctor/packs/explain/allow-once and the hook miss path. SPM product name is still `rv`. Install stages it next to the hook client under the on-disk name `rv-cli`. That name is a sibling path, not a CLI surface.
_Avoid_: rv-cli CLI, operator CLI, three CLIs

**Evaluate session**:
The compiled day-one packs from which a Decision is produced. TTY test/explain and a hook miss share one; TTY never asks rvd. It does not honor allow-once grants.
_Avoid_: in-process fallback, composer, warm evaluate

**Matching view**:
The T1-normalized command text an EvaluationResult was decided on. The Policy gate fingerprints it; TTY and XPC explain read it.
_Avoid_: raw argv as the grant key

**Policy gate**:
The step after the Evaluate session. On engine deny, hook miss and rvd may spend one allow-once grant for this matching view and cwd and return allow. Missing cwd still skips honor. Host codecs populate cwd when the adapter/host provides it. Hook process directory is still not a fill-in (adapter process.cwd is allowed as fallback). TTY test/explain and XPC explain/classify use the same gate without spending. Not a pack rule.
_Avoid_: honor wrapper, consume-on-evaluate

**Allow-once grant**:
A single-use unlock for one matching view plus cwd. Spent by the Policy gate after an engine deny. The hook wire never carries a code.
_Avoid_: bypass, pending code, exception, consume-then-evaluate

**Unlockable deny**:
A pack deny the Policy gate could spend (matching view + cwd present). Not `core.secrets`, not `builtin.action`, not incomplete evaluate. Spend-first hosts (Pi, OpenCode) pause on the hook door; deny-or-TTY hosts stay deny.
_Avoid_: inferring Ask from deny JSON that happens to carry a rule id

**Host adapter**:
The rv-owned integration for one supported host that turns a host shell event into a Hook request and carries the Hook mapper's result back as the host-native block plus optional display-only chrome. Setup installs a Host adapter; it does not define its behavior.
_Avoid_: host hook, HostCodec (only one part)

**Host adapter installation state**:
The read-only classification of one owned Host adapter path: missing, absent-file, occupied, broken, or wired. RVCLI derives it from host detection, resource identity, and the baked executable path; setup and doctor consume the same snapshot.
_Avoid_: parsing Host adapter behavior in setup or doctor

**Service health**:
The read-only classification of rvd reachability: reachable, down, not-installed, skew, or request-failed. RVCLI derives it from typed diagnostics plus optional LaunchAgent installed/loaded; doctor and status format the same facts.
_Avoid_: mapping down/skew/request-failed separately in doctor or status

**Hook mapper**:
EvaluationResult to HookWire after the Policy gate. One Decision switch, HostCodecs (Claude uses the rich encoder plus official `permissionDecision: ask`; OpenClaw is short deny; Hermes is short deny/ask JSON; Codex uses official older `decision: block` on stdout + blocking reason on stderr + exit 2, not Claude permission deny; Cursor uses official native `permission: deny` + `user_message`/`agent_message` + exit 0, not Claude permissionDecision and not Codex block). Owns hook voice. Product Ask is `HostNativeAsk.verdict(host:result:cwd:bound:)`; adapters honor `decision:ask` only. Spend-first hosts: Pi, OpenCode, Claude, Hermes.
_Avoid_: per-codec Decision switch, inferring Ask from deny JSON

**Hook voice**:
The native host deny sentence the hook mapper produces. TTY panels do not own it.
_Avoid_: hostDenyText as Presentation, briefing

**Enabled packs**:
The pack IDs on an evaluate request. Empty means none — not the catalog, not an implied day-one refill.
_Avoid_: refill, default packs

**Day-one packs**:
core.filesystem, core.git, and system.disk. v1 evaluate always uses these; the catalog does not change a Decision.
_Avoid_: live catalog, enabled catalog

**Explain pipeline**:
The stages an EvaluationResult already took, in evaluation order: normalize, quick-reject, safe, destructive, default. TTY explain and XPC explain show the same stages. XPC `ExplainStage.name` is that kebab-case id (`quick-reject`, not camelCase `quickReject`); `elapsedMs` is currently always 0.
_Avoid_: explain projection, briefing, ExplainStage (the IPC timing row)

**Explain step**:
One stage in the Explain pipeline, including that stage's outcome (scanned or skipped, rule hit or none, allow or incomplete).
_Avoid_: ExplainStage

**Secret-path guard**:
The allow-path scan of path-shaped operands on the matching view against `SecretPathCatalog`. Deny `rule_id` is `core.secrets:<pattern>`. Not a catalog pack. Not a third day-one ICU pack. Does not rewrite matching view.
_Avoid_: secret pack, path sandbox, realpath

**Session forensics**:
Offline `rv scan` / `rv scan sessions`: read known host session stores (or a path of known layouts), extract shell candidates, run the same `evaluate`, list deny-only findings. Not `RVHistory`, not repo/CI `rv scan repo`, not live hook enforcement. Fence: `docs/factory/specs/phase-4-session-scan.md`.
_Avoid_: history scan, recon, audit log (unless meaning this CLI)

**EvaluationWorld**:
The single assembly door in RVService: snapshots, walk vs compile (`PackCoverage`), lazy `GatedEvaluate`. TTY test, hook miss, and warm rvd call `assemble` / `coverage` / `walkedPackIDs`. Nil or unreadable HOME is day-one walk inside the module. Matching view for mint/allowlist/explain render is `matchingView(of:)` on this door, not `Normalize` in CLI.
_Avoid_: EnabledPacks.resolve as a caller-facing door, a public pack-ID bag named EvaluationWorld, makeCatalog/compileEnabledIDs, MatchingViews.t1

**EvaluationRoute**:
The client Decision from transport and advertised service semver to an EvaluationPath (xpc or inProcess). `path(for:)` owns unprovable compatibility (missing, empty, or unparseable advertised service semver → inProcess). Adapters: `ServiceClient.evaluate` and C `rv_should_miss_replay`. Server empty-client handshake stays `isMajorSkewed` (not skew).
_Avoid_: isMajorSkew at the client evaluate call site, flipping isMajorSkew true on parse failure, transportPresent Bool
