# Host Ask build map (OPE-268)

Plan only. No Ask code. Investigation: [host-ask.md](host-ask.md) (OPE-267, accepted). Linux + macOS. No Windows.

OPE-264 pulls shared pieces plus Pi / OpenCode / Claude. Then OpenClaw. Then Hermes. Do not start OPE-253.

## Shared: grant, bridge, pause

**Grant (shared).** One store: `AllowOnceStore` + `PolicyGate.apply`. Key today is `{matchingView, cwd}`. TTY `rv allow-once` mint/redeem stays. Hook consume stays `GatedEvaluate` apply. OPE-158 may widen the key; it does not add a second ledger.

`AllowOnceStore.mint` is TTY-gated. A hook child cannot run `rv allow-once`. Host Allow once is a new writer on this same actor/file — plant and spend this turn, or spend a TTY grant. Do not invent a second grant store. Do not treat a host-native Allow as a grant unless that writer ran.

Indeterminate never consumes. Replay without a live grant is ask or deny again, never silent allow.

**Bridge (shared).** `ApprovalContinuation.hostNative` exists. There is no `ApprovalBridge` yet. Product Ask is `BoundReview.mandatoryHuman` (`02.md` `.ask`). `BoundReview.decision` still projects Ask to `Decision.deny`, so `HookMapper` never pauses.

Shared work: stop collapsing Ask to deny before hosts that can spend first (Pi confirm); carry Ask on the operator→adapter wire without adding `Decision.ask`; resolve Allow once / Deny through PolicyGate. Grok, OpenCode, Claude (until a spend-first callback), and any host with no pause, stay deny or TTY — never `encodeAllow` on Ask.

`PendingApproval` / OPE-246 is after host Ask. Not the 264 pause.

Pause only for `mandatoryHuman` once that verdict is on the hook door. Pack deny stays `encodeDeny`. TTY allow-once still unlocks pack deny.

**Pause (host-specific).** Official APIs from 267 only. Shared is when to pause. Fail-closed: no UI, confirm false, timeout, cancel, crash, missing API → deny or TTY, never silent allow. A pause that lets the tool run before a PolicyGate spend is leftover-ask-as-permit — do not call it. Stay deny-or-TTY until a same-turn or callback spend exists (Pi confirm, OpenClaw `onResolution`).

## Per host (only 267)

**Pi (264).** Official pause: `ctx.ui.confirm` in `rv-guard.ts` (tests forbid it today). Same `tool_call`: yes → PolicyGate spend then allow; no / `hasUI` false / confirm false → `{ block: true }`. Card stays chrome. Confirm-yes without the store is the 267 hole.

**OpenCode (264).** No official RV pause. Plugin path is throw or return. Do not invent `permission.ask`. Ask → throw or TTY (the tool does not run). Host permission prompts do not reach PolicyGate. Toast stays chrome.

**Claude (264).** Official pause exists (`permissionDecision: "ask"`) but first-call host Allow runs the tool with no PolicyGate spend — leftover-ask-as-permit (267, CL-later-ask). Do not emit `"ask"` until a callback can spend first, then allow. Until that callback exists: deny or TTY, same as OpenCode. Documented `hookSpecificOutput` keys only if ask is ever emitted (extras fail-open a deny). TTY allow-once remains the RV grant.

**OpenClaw (after 264).** Official pause: `requireApproval`. Hard deny stays `{ block: true }` (`block` wins). `onResolution` allow-once → PolicyGate spend then allow. Host `allow-always` is not this grant and not createRule; this-call-only or deny. Timeout / no route / cancel → block.

**Hermes (after OpenClaw).** Official pause exists (`{"action": "approve"}`) but first-call Hermes-gate Allow runs the tool with no PolicyGate spend — leftover-ask-as-permit (267). Do not return `approve` until a callback can spend first, then allow. Until that callback exists: `{ action: "block" }` or TTY. Exceptions still block.

## Order

1. Shared grant writer + bridge (before any confirm-yes, or the command runs with no store).
2. **OPE-264:** Pi, OpenCode, Claude.
3. OpenClaw.
4. Hermes.

Grok stays deny-or-TTY. No extra hosts.

## Parked

Auto-review / OPE-253. No reviewer path. No live `reviewEligible`. `PendingApproval` always-on. createRule / Always Allow.

264 can be pulled from shared grant writer + bridge, Pi spend-then-allow, and OpenCode / Claude deny-or-TTY. This ticket writes no Ask.
