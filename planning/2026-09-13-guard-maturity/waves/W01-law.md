# Wave extract: Guard maturity / W01 — Law

**Parent program:** `/Users/chriskarani/CodingProjects/rv/planning/2026-09-13-guard-maturity-implementable-program.md`  
**Wave:** W1  
**Mode:** standard  
**max_units / max_parallel / agent_budget:** 4 / 3 / 512

## Global reject list (copy from parent)

- `RV_BYPASS`
- Allow because XPC missed
- Starting OPE-156 / Host Ask / Auto-review / `ProposedAction.file`
- Foreign product names in-tree
- Third safety level
- Live-HOME
- Reordering 02.md § Order
- Touching file-tool-secrets exclusive engine/policy files

## Tree-truth for this wave only

| Unit | Prior status | Notes |
|------|--------------|-------|
| w1-never-slip | open | new `docs/architecture/never-slip.md` |
| w1-residual | open | new `docs/architecture/residual-risk.md` |
| w1-queue | open | pointer + vocabulary |
| w1-review | open | evaluate-parity skill + landmines Maturity section |

## Units

Full unit fields live in the parent program § Wave W1. Exclusive paths:

| Unit | Writes |
|------|--------|
| w1-never-slip | `docs/architecture/never-slip.md` |
| w1-residual | `docs/architecture/residual-risk.md` |
| w1-queue | `docs/architecture/02.md`, `docs/factory/STATUS.md`, `CONTEXT.md` |
| w1-review | `.grok/skills/swift-evaluate-parity/SKILL.md`, `.grok/skills/swift-evaluate-parity/references/landmines.md` |

Order: `w1-never-slip` ∥ `w1-residual`; then `w1-queue` ∥ `w1-review`.

## Wave product_oracle_cmds

1. `rg -n 'Never-slip' docs/architecture/02.md CONTEXT.md`
2. `rg -n 'Residual risk' CONTEXT.md docs/architecture/residual-risk.md`
3. `{ rg -n 'paranoid' docs/architecture/never-slip.md docs/architecture/residual-risk.md CONTEXT.md docs/architecture/02.md && exit 1; }`

## Wave done when

- All four units merged
- Both law files exist
- 02.md **Maturity overlay** subsection present; § Order unchanged
- No residual that parent program marks as ship-blocker
