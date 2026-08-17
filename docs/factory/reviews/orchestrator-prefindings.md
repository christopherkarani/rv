# Orchestrator prefindings

Written while FP/FN/known-unknown agents run. Merge with their files; do not treat this as a substitute.

## Must lock (done in PLAN.md “Locked resolutions”)

- Decision associated values vs T1 flat enum
- DCG medium/low allow vs SKILL.md block
- PackID must accept `strict_git` / `package_managers`
- T0 library-only vs T2/T3 executables
- T8 after T1, CLI rebase onto T2
- Missing binary fail-open vs XPC in-process
- Grok deny JSON + both tool-name spellings
- No allow-once code on the hook wire

## Watch

- T1 `dayOnePackIDs` used `!` — forbidden on production paths
- 1d Open question 609 vs T5.1 adapter fail-open — PLAN now locks it
- host-contracts-v1.md said missing rv → block; PLAN now says adapter fail-open
- T9 enable algebra vs T1 “core cannot be disabled” (T9 allows explicit disable + doctor warn)
- Grok parse-failure fail-open is host honesty, not an XPC hole
