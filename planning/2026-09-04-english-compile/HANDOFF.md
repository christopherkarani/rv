# Handoff — English compile

**Program:** typed rules from English (W1 = form + matcher, not the model yet)  
**Runner:** `.grok/workflows/english-compile-swift.rhai` — **not** Zig implementor  
**Plan:** `planning/2026-09-04-english-compile-implementable-program.md`

## Do first

```text
workflow name=english-compile-swift
agent_budget=256
args={ wave: "W1", mode: "full", repo: "/Users/chriskarani/CodingProjects/rv" }
```

Or paste `PROMPT.md` into a new Grok session.

## Already true

- Spike Mac app in `scratch/english-review` is throwaway. Do not import it.
- `ActionPolicyEngine` + `GitAction.push` exist. `PolicyPredicate` / `TypedRule` do not.
- `RulePinning` is fingerprint allowlist, not English compile (W2).
- Host Ask / live Auto-review are 02.md later. Do not start them.

## W1 done when

Typed deny of force-push to `main` matches. Typed allow cannot un-block the wall. `rv policy show` runs on a temp HOME. `tools/gate.sh RVDomainTests RVPolicyTests RVCLITests` green.
