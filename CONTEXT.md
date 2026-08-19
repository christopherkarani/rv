# rv

Mac-native destructive-command guard for coding-agent shell hooks. Day-one hosts: Pi, Grok, OpenCode.

## Language

**Evaluate session**:
The compiled day-one packs from which a Decision is produced. TTY test/explain and a hook miss share one; TTY never asks rvd. It does not honor allow-once grants.
_Avoid_: in-process fallback, composer, warm evaluate

**Matching view**:
The T1-normalized command text an EvaluationResult was decided on. The Policy gate fingerprints it; TTY and XPC explain read it.
_Avoid_: raw argv as the grant key

**Policy gate**:
The step after the Evaluate session. On engine deny, hook miss and rvd may spend one allow-once grant for this matching view and cwd and return allow. TTY test/explain uses the same gate without spending. Not a pack rule.
_Avoid_: honor wrapper, consume-on-evaluate

**Allow-once grant**:
A single-use unlock for one matching view plus cwd. Spent by the Policy gate. The hook wire never carries a code.
_Avoid_: bypass, pending code, exception

**Hook mapper**:
EvaluationResult to HookWire after the Policy gate. One Decision switch, three HostCodecs. Owns hook voice.
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
