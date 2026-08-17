# Stress test 1

Hunt: remaining contradictions that would make two implementers ship different products after adversarial FN / FP / known-unknowns were merged into PLAN locked resolutions. Checked that FN-01..09 and K0–K12 were actually patched in PLAN / specs / prompts, not just listed.

Read: `docs/factory/PLAN.md`, `HANDOFF.md`, `reviews/adversarial-fn.md`, `reviews/adversarial-known-unknowns.md`, `reviews/adversarial-fp.md`, `prompts/T0.md`–`T9.md`, every file under `docs/factory/specs/`, plus `references/host-contracts-v1.md` and `references/dcg-0.11.0-notes.md`. No product Swift. No ryk edits.

## Verdict (Fix required)

PLAN locked resolutions 1–19 were real, but several owning specs still encoded the pre-lock product. Two faithful implementers could still have shipped different Decision wires, different T2 graphs, different Pi miss policy, different T1 corpora, and a T8 consume race. This pass applied the smallest owning-spec / PLAN edits. Stress-2 must re-read those files. Do not kick off T0 until stress-2 stamps the patches.

## Still broken (must patch)

These were live forks at the start of this pass. Each is patched in the owning spec or PLAN unless noted.

1. **K1 leftover — PLAN “What 1:1 means” still named SKILL.md as the scoreboard.** Locked resolution 2 says engine source. T0 would have copied the old sentence into `PARITY.md`. **Patched:** PLAN scoreboard sentence + T0 `PARITY.md` table + T3 evaluate meaning.

2. **K5 leftover — T1 ICU load was still two opposite rules.** “Compile fail = load error for that JSON file” vs “quarantine by name, still load the pack.” **Patched:** T1 now matches PLAN #16 (quarantine by name; never quarantine `reset-hard` / `fork-bomb`).

3. **K6 leftover — `EvaluationResult` snippet was invalid Swift and left `SafeMatch` optional.** **Patched:** named `SafeMatch`; no tuples.

4. **K7 leftover — T2 spec forbade a `Package.swift` graph change while requiring `rv test`.** Prompt already allowed ArgumentParser. **Already holding in current T2** (PLAN #4 + `main.swift` + pin). No further edit.

5. **K9 leftover — T2 robot `rule_id` was pattern-only (`reset-hard`).** PLAN #13 is colon form. **Already holding in current T2** (`core.git:reset-hard`).

6. **K10 leftover — T9 example/table used `reason`; T1 schema is `description`.** **Patched:** T9 `description` + `reason` decode alias.

7. **K12 leftover — T8 allowlist / `RVPolicyPaths` still mentioned `XDG_CONFIG_HOME`.** **Already holding in current T8** (`$HOME/.config/rv` only).

8. **FN-01 / FP-02 leftover — T4.5 had no stash-drop or oversize fixtures; T2 `hostDenyText` could be read as “any match ⇒ deny.”** **Patched:** T4.5 `allow-medium-stash-drop` + `deny-indeterminate-oversize`; T4.3 “do not treat `matched != nil` as deny.” Current T2 already returns `nil` on allow and the PLAN #6 sentence on indeterminate.

9. **FN-04 leftover — acceptance named extras in 7b but did not require a true-positive per non-semantic destructive name.** **Patched:** T1 7d + 7e; near-miss table now includes DCG force-push / restore landmines; deny companions include `git reset '--hard'`.

10. **FN-05 leftover — T3 handshake could still `ok` with an empty core registry.** Prompt already forbade it. **Patched:** T3 `HelloAck.ok` false if core packs missing/unloadable; test plan row 16.

11. **FN-06 leftover — T5.1 / Q7 used to say catch-and-allow on missing `rv`; T5.3 / PLAN #6 / T5 prompt say block.** **Already holding in current T5.1 / Q7.** **Patched this pass:** T5.4 adapter fixtures (deny JSON + exit 0; ENOENT → `rv missing`; timeout/crash → `rv failed`).

12. **FN-07 leftover — T7.1 defined `broken` but T7.2 had no `/nonexistent/rv` fixture.** **Patched.**

13. **FN-09 leftover — T8 consume was actor-only (one process).** PLAN #19 needs on-disk CAS for two hook children while `rvd` is down. **Patched:** file CAS + two-process test.

14. **K3 leftover — T6.3 installs the LaunchAgent; T6.4 did not test it.** **Patched:** L4 LaunchAgent row. Q11 already locked.

15. **K0 leftover — T3 said `Decision` encodes “as in T1 (string newtypes).”** T1 `Decision` has associated values. **Patched:** string discriminator + optional deny payload.

16. **Reference still forks (not edited — outside owning spec / PLAN).** `references/host-contracts-v1.md` still says missing `rv` on Pi is residual **fail-open**. PLAN #6, T5.1, T5.3, Q7, and `prompts/T5.md` say **block** with `rv missing`. PLAN wins. Stress-2 should strike the reference sentence so T4/T5 agents who read host-contracts first cannot resurrect FN-06.

## Patched and holding

Checked against PLAN locked resolutions and the current specs/prompts. “Holding” means the lock is in the owning file, not only listed in PLAN.

| ID | Lock | Where it actually lives |
|---|---|---|
| **FN-01** | `indeterminate` → hook deny, not empty allow | PLAN #6; T4.3 indeterminate row; T8 PolicyGate rule 1; T4.5 oversize fixture; T2 `hostDenyText` on indeterminate |
| **FN-02** | Force-scan empty-paren / fork-bomb; never quarantine `fork-bomb` | PLAN #17; T1 quick-reject; T1 ICU never-quarantine; T1 7b corpus |
| **FN-03** | Role-aware quotes; `"git" reset --hard` and `git reset '--hard'` deny | PLAN #14; T1 normalize; T1 deny companions + acceptance 7 |
| **FN-04** | Day-one filesystem/git bypasses must have true-positives | T1 7b (`find -delete`, `unlink ~/.ssh/…`, redirect `/etc/passwd`, `rm -rf ~`, `git push -uf`, fork-bomb) + 7d (every non-semantic destructive name) |
| **FN-05** | Missing/unloadable day-one packs must not serve allow | PLAN #15; T1 `IndeterminateReason.corePacksUnavailable`; T3 handshake refuse; `prompts/T3.md` |
| **FN-06** | Missing `rv` / started-`rv` fault on Pi/OpenCode is block, not catch-and-allow | PLAN #6; T5.1; T5.3; Q7; T5.4 adapter fixtures; `prompts/T5.md` |
| **FN-07** | Doctor `wired` requires executable baked path | PLAN #18; T7.1 `wired` / `broken`; T7.2 `/nonexistent/rv` |
| **FN-08** | T9 must not skip-and-serve critical/high ICU compile-fail | PLAN #16; T9 extractor: fail enable, do not skip-and-serve |
| **FN-09** | Consume is `{ command, cwd }`; on-disk CAS across processes | PLAN #9 / #19; T3 `AllowOnceConsumeParams`; T8 file CAS + two-process test; `prompts/T8.md` |
| **K0** | `Decision` is `allow` \| `deny(Deny)` \| `indeterminate(…)` | PLAN #1; T1 types; T3 IPC discriminator + payload; `prompts/T1.md` |
| **K1** | Scoreboard is 0.11.0 engine, not SKILL.md; stash-drop allow + match | PLAN #2 + “What 1:1 means”; T0 `PARITY.md`; T1 severity table + quarantine; notes landmine line |
| **K2** | Miss policy: XPC → in-process; indeterminate → deny; missing `rv` per PLAN #6 | PLAN #6; T3 fallback; T4.3; T5.1/T5.3 |
| **K3** | T6 owns LaunchAgent install | PLAN #10; T6.3; T6.4; Q11 |
| **K4** | PackID dotted child optional | PLAN #3; T1 regex; T9 `strict_git` / `package_managers` |
| **K5** | ICU: quarantine by name, still load pack; never drop `reset-hard` / `fork-bomb` | PLAN #16; T1 PatternEngine bullets |
| **K6** | `SafeMatch` named type (Codable for T3) | T1 `EvaluationResult` |
| **K7** | T2 adds ArgumentParser + `rv`; T3 adds `rvd`; T8/T9 do not | PLAN #4 / #5; T0; T2; T3 Depends-on; T8 rebase onto T2 |
| **K8** | `allowOnce.consume` spends a grant, not a code | PLAN #9; T3; T8; both prompts |
| **K9** | `rawValue` colon; display slash; robot colon | PLAN #13; T1 `RuleID`; T2 pretty slash + robot colon |
| **K10** | Destructive JSON key is `description` | T1 schema; T9 field table + alias |
| **K11** | Grok deny is JSON + exit 0, not exit 2 | PLAN #7; T4.3; `prompts/T4.md` |
| **K12** | Config dir is `$HOME/.config/rv` only | PLAN #12; T6; T8 paths |
| **FP-01 / FP-02 / FP-03** | `$TMPDIR` deny; stash-drop allow; `--force-with-lease` / `feature--force` / restore-staged near-misses | T1 quarantine + near-miss table; T2/T4 medium-match allow |

Prompts T0–T9 already carried most locks (associated-value `Decision`, extra deny rows, ArgumentParser, grant consume, Pi block, HOME-only, no `RV_BYPASS`). The holes were specs that still contradicted those prompts.

## Residual risk (do not block Go Ready)

- **`host-contracts-v1.md` Pi miss sentence** still says fail-open. Owning spec + PLAN + T5 prompt say block. PLAN wins. Strike on stress-2 so the reference cannot re-fork T5.
- **FP-04 vs PLAN #6.** Blocking on a missing `rv` wedges every Pi/OpenCode `bash` (including `git status`). That is the locked miss policy, not a silent allow-all. Doctor `broken` (FN-07) is the operator signal. Do not re-litigate in T5.
- **T7 / T4 prompts** do not list the new `broken` / stash-drop / oversize fixtures. Specs do. Implementers who follow the spec checkboxes will hit them.
- **Quoted `-f` / `-rf`** are implied by role-aware normalize, not named as extra corpus rows. Residual FN-03 test-gap.
- **T1d Q9 / T8 Q1** still narrate slash vs colon. PLAN #13 already picked. Stale questions, not a third wire.
- **Grok host fail-open** if `rv` never starts remains hook-grade residual (PLAN #6). Honest, not an rv XPC hole.
- **HANDOFF** still says reviews / Go Ready are open. Expected until cohesiveness stamps.
- **Phase 4+ fence** is intact. No v1 implementer should pull scan / MCP / Mac app / extra hosts.

No product Swift was written. No ryk files were edited.
