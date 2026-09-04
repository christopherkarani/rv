# Wave extract: English compile / W1 — typed form

**Parent program:** `/Users/chriskarani/CodingProjects/rv/planning/2026-09-04-english-compile-implementable-program.md`  
**Wave:** W1  
**Mode:** full  
**max_units / max_parallel / agent_budget:** 8 / serial-or-3 / 256 (Swift workflow, not Zig 1024)  
**Runner:** `.grok/workflows/english-compile-swift.rhai`

## Global reject list (copy from parent)

- Zig implementor
- Live Auto-review / hook bind
- Host Ask / companion app
- MCP / npm / matching argv
- Saving English as the matcher
- scratch/english-review import
- `swift package clean`

## Tree-truth for this wave only

| Unit | Prior status | Notes |
|------|--------------|-------|
| w1-law | open | no english-compile.md |
| w1-predicate … w1-cli | open | no AST types |

## Units

Use parent program §6 W1 unit fields verbatim (w1-law through w1-cli). Do not add units.

## Wave product_oracle_cmds

1. `tools/gate.sh RVDomainTests`
2. `tools/gate.sh RVPolicyTests`
3. `tools/gate.sh RVCLITests`
4. Build with real HOME, then `HOME=$tmp .build/arm64-apple-macosx/debug/rv policy show` (do not wrap `tools/swift-6.3.3` in temp HOME — Darwin pin lives under `$HOME/Library/Developer/Toolchains`)
5. Fail if `rg scratch/english-review Sources Package.swift` hits

## Wave done when

- All eight units passed dual review (or workflow equivalent)
- Live verify PASS
- No residual the parent marks as ship-blocker for W1
