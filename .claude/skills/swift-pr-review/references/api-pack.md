# Swift API review pack

Load this before reviewing or fixing **public / package / open** Swift
APIs. Then load the ADG skill. Do not invent local naming rules.

## Required loads

1. `.claude/skills/swift-api-design-guidelines/SKILL.md`
2. On demand (not all up front):
   - `references/fundamentals.md`
   - `references/promote-clear-usage.md`
   - `references/strive-for-fluent-usage.md`
   - `references/parameters.md`
   - `references/argument-labels.md`
   - `references/special-instructions.md`
3. Project overlay wins: `AGENTS.md`, `docs/dev/SWIFT.md`, ticket/PLAN
   specs that **name** a symbol

## Scope

- Review **declarations and call sites together**.
- Only APIs this diff **adds or re-signs**, plus their in-diff call sites.
- Do not audit unchanged APIs.
- Missing `///` only on declarations this diff added or re-signed.

## Spec lock

If PLAN / a ticket spec / `AGENTS.md` **names** a function, field, or
factory, that name is a constraint. Document it. Do **not** rename.
`Fixable: no`. AutoFix: no.

## Hunt (high conviction)

- Call site is unclear without reading the body
- Needless type words (`displayRuleID(_ ruleID:)`)
- Weak types (`String`, `Int`, `Any`) without a role noun
- Boolean queries that do not read as assertions (`isEmpty`, `intersects`)
- Side-effect-free APIs named as verbs; factories not `make…` / not an `init`
- Unlabeled remaining arguments; unlabeled members on a **public** tuple
- Free function that collides with an instance property (call sites need
  a module qualifier)
- Overloads distinguished only by return type

## Severity

| Finding | Severity |
|---------|----------|
| Public call site ambiguous / wrong labels on a seam | major |
| New public decl with no `///` | minor |
| Spec-locked leftover | nit / report-only |
| Taste rename, no call-site gain | drop or nit |

Pure restyle with no behavior delta is **minor**, never blocker.

## AutoFix

**yes:** role/label rename that is not spec-locked; hide a leaked
`public let`; add `///` on a new public decl; move a colliding free
function onto the type it describes.

**no:** spec-locked rename; wholesale `fooViewModel(from:)` → `init`
when the ticket names the factory.
