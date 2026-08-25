# rv

Mac-native destructive-command guard for coding-agent shell hooks. Day-one hosts: Pi, Grok, OpenCode, Claude.

## Language

**Evaluate session**:
The compiled day-one packs from which a Decision is produced. TTY test/explain and a hook miss share one; TTY never asks rvd. It does not honor allow-once grants.
_Avoid_: in-process fallback, composer, warm evaluate

**Matching view**:
The T1-normalized command text an EvaluationResult was decided on. The Policy gate fingerprints it; TTY and XPC explain read it.
_Avoid_: raw argv as the grant key

**Policy gate**:
The step after the Evaluate session. On engine deny, hook miss and rvd may spend one allow-once grant for this matching view and cwd and return allow. Missing cwd skips honor — it is not filled in from the process directory. Pi and OpenCode codecs do not populate cwd, so those hosts cannot honor grants until the codecs send it. Grok and Claude can when the event carries cwd. TTY test/explain and XPC explain/classify use the same gate without spending. Not a pack rule.
_Avoid_: honor wrapper, consume-on-evaluate

**Allow-once grant**:
A single-use unlock for one matching view plus cwd. Spent by the Policy gate after an engine deny. The hook wire never carries a code.
_Avoid_: bypass, pending code, exception, consume-then-evaluate

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
EvaluationResult to HookWire after the Policy gate. One Decision switch, four HostCodecs (Claude uses the rich encoder). Owns hook voice.
_Avoid_: per-codec Decision switch

**Hook voice**:
The native host deny sentence the hook mapper produces. TTY panels do not own it.
_Avoid_: hostDenyText as Presentation, briefing

**Enabled packs**:
The pack IDs on an evaluate request. Empty means none — not the catalog, not an implied day-one refill.
_Avoid_: refill, default packs

**Day-one packs**:
core.git and core.filesystem. v1 evaluate always uses these two; the catalog does not change a Decision.
_Avoid_: live catalog, enabled catalog

**Explain pipeline**:
The stages an EvaluationResult already took, in evaluation order: normalize, quick-reject, safe, destructive, default. TTY explain and XPC explain show the same stages. XPC `ExplainStage.name` is that kebab-case id (`quick-reject`, not camelCase `quickReject`); `elapsedMs` is currently always 0.
_Avoid_: explain projection, briefing, ExplainStage (the IPC timing row)

**Explain step**:
One stage in the Explain pipeline, including that stage's outcome (scanned or skipped, rule hit or none, allow or incomplete).
_Avoid_: ExplainStage
