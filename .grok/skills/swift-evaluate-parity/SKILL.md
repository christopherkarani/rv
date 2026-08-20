---
name: swift-evaluate-parity
description: >
  Pinned 0.11.0 evaluate contract for rv. Use when changing RVEngine /
  RVDomain evaluate types, day-one pack JSON, CompiledPacks, normalize /
  quote-mask, quick-reject, walkers, corePacksUnavailable, or
  Tests/**/corpus/*. Not for hook or XPC Decision encoding
  (swift-hook-xpc). Also /swift-evaluate-parity.
metadata:
  short-description: pin evaluate contract
---

# swift-evaluate-parity

Internal. The T1 contract as a skill.

The **scoreboard** is `docs/dev/PARITY.md` + `vendor/parity/PIN` (same
`Decision` + `rule_id` as the pinned 0.11.0 engine source). Marketing rows
that disagree are **quarantine**, not the scoreboard. This file is not the
scoreboard.

Spec: `docs/factory/specs/phase-1-engine.md`. PLAN wins conflicts.
Landmines: [references/landmines.md](references/landmines.md).

## Load first

1. `docs/dev/PARITY.md` and `vendor/parity/PIN`
2. `Sources/RVDomain/Decision.swift`, `Severity.swift`, `EvaluationResult.swift`
3. `Sources/RVEngine/Evaluate.swift`, `Normalize.swift`, `QuickReject.swift`,
   `CompiledPacks.swift`, `PatternEngine.swift`, `ICUPatternEngine.swift`
4. `Tests/RVEngineTests/Fixtures/corpus/` (`deny.json`, `near-miss.json`,
   `quarantine.json`, `skill-table.json`)

## Steps

1. State the expected `Decision` + `rule_id` from the pin, not from a
   marketing table.
2. Keep `evaluate` **pure**. Clock, disk, and `ProcessInfo` stay out.
3. Preserve evaluation order. Do not “simplify” extracted regexes.
4. Add or update a corpus row that would fail if the change is wrong.
5. Prove on 6.3.3 (not `/usr/bin/swift`):

   ```bash
   tools/swift-6.3.3 --version   # expect Apple Swift version 6.3.3
   tools/gate.sh --quiet RVEngineTests RVCorpusTests
   tools/swift-6.3.3 test --filter packLoad
   ```

6. Run `tools/gate.sh` (or the filters above) before claiming done.

## Order (locked)

On the **raw** command, before normalize:

- Empty / whitespace-only after trim → `allow`.
- `raw.utf8.count > 65_536` → `indeterminate(.commandTooLarge)`,
  `quickRejected == false`.
- Missing or empty `core.git` / `core.filesystem` snapshots →
  `indeterminate(.corePacksUnavailable)`. Not a fake `deny` `rule_id`.

Then: normalize → quick-reject → **per enabled pack, lex by `PackID.rawValue`**
safe then destructive (a safe hit skips **that pack only**) → default allow.

- Budget exhausted → `indeterminate(.budgetExhausted)`.
- Critical / high match → `deny` + `RuleMatch`.
- Medium / low match → `allow` + `RuleMatch`. Keep scanning for a blocker.
- Unknown command (finished scan, no rule hit) → `allow`. That is not
  fail-closed on unknown. Missing core packs, oversize, and budget are
  `indeterminate`, not unknown. Hooks must not treat `indeterminate` as
  allow (`swift-hook-xpc`).
- `evaluate` is generic over `PatternEngine` plus already-compiled packs.
  Do not restyle the signature to `some`. `RVEngine` does not import
  `RVPacks`. Packs are JSON data, not Swift files.

`Severity.blocksByDefault` is critical/high only (`Sources/RVDomain/Severity.swift`).
No boolean `isDenied`. `Decision` shape lives in `Decision.swift`. Deny always
carries `RuleID` + reason. `RuleID.rawValue` is `pack:pattern`
(`core.git:reset-hard`). Display slash form is a T2 concern.

Multi-segment: split the matching view on top-level `&&` `||` `;` `|`.
First `deny` / `indeterminate` wins. If every segment allows, evaluate the
full string once.

## PatternEngine

ICU first (`NSRegularExpression`). Compile at pack load, not in the hot loop.
A compile miss quarantines that **pattern name** and its rows; the pack
still loads. Never quarantine `core.git:reset-hard` or
`core.filesystem:fork-bomb`.

Extract the 0.11.0 regex. Do not rewrite a walker to make a test green.

## Corpus

| File | Role |
|---|---|
| `skill-table.json` | Command rows from upstream skill tables. **`expected` = pin `Decision` + `rule_id`.** Never write a marketing Decision here. |
| `deny.json` | Extra true-positives (wrappers, multi-segment, filesystem bypasses). Bare `git reset --hard` stays in `skill-table.json`. Do not empty this file down to that one command. Marketing “blocked” rows that the pin allows go to `quarantine.json`, never here. |
| `near-miss.json` | Must **allow** (see landmines). Shrinking this file is a fail. Those landmine ids are required; deleting a row to go green is a fail. |
| `quarantine.json` | SKILL.md drift + ICU misses. Expected decision stays the pin. |

Day-one packs only: `core.git` + `core.filesystem`. T9 imports the rest
default-off.

## Preflight

**Run `tools/gate.sh --quiet RVEngineTests RVCorpusTests` (and `packLoad` if
needed).** Gate runs `tools/preflight.sh` then filtered tests on 6.3.3. Then
re-read the remaining list for semantic judgments.

- [ ] Expected verdict matches `PARITY.md`, not a marketing row.
- [ ] Raw gates still run before normalize; then per-pack lex safe → destructive.
- [ ] Medium/low stays `allow` + match (`git stash drop` is the canary).
- [ ] `git stash drop` is not a `deny.json` row. A marketing “blocked” line
      is `quarantine.json` with `expected: allow`.
- [ ] Empty core packs / oversize / budget → `indeterminate`, not an invented deny.
- [ ] No regex in the diff was “simplified.”
- [ ] `near-miss.json` still contains the landmine rows.
- [ ] `reset-hard` and `fork-bomb` are not in `quarantine.json`.
- [ ] `evaluate` gained no I/O.
- [ ] `RVEngineTests` + `RVCorpusTests` + `packLoad` green via `tools/gate.sh` / `tools/swift-6.3.3`.
