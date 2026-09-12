# Wave W1 extract — file-tool secrets

**Parent:** `/Users/chriskarani/CodingProjects/rv/planning/2026-09-12-file-tool-secrets-implementable-program.md`  
**mode:** full · **max_units:** 9 · **max_parallel:** 3 · **agent_budget:** 1024

Honor parent §2 locks, §3 reject list, §5 ownership. Units: `w1-law-core`, `w1-law-hosts`, `w1-file`, `w1-eval`, `w1-dispatch`, `w1-claude`, `w1-cursor`, `w1-grok`, `w1-setup`.

## Reject (copy)

- Fake `cat <path>` into pack evaluate
- `ProposedAction.file` / `.mcp`
- Grep / Glob / MCP matchers
- Omit Claude matcher (MCP would hit the hook)
- Remove Cursor `beforeShellExecution`
- `RV_BYPASS`; allow because XPC missed
- Official Claude `permissionDecision: ask`
- Competitor names in tree files

## Parallel

- `w1-law-core` ∥ `w1-law-hosts` ∥ `w1-file`
- then `w1-eval` → `w1-dispatch`
- then `w1-claude` ∥ `w1-cursor` ∥ `w1-grok`
- then `w1-setup`

## Oracles

See parent §4 rows 1–6. Shell `git reset --hard` on Grok must still deny.
