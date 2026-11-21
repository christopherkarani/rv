# HTML Report Style — Swift Type-System Architecture

Render a single local HTML file with inline CSS.

The visual style should feel like a Vercel engineering design review:

- white background
- near-black text
- thin neutral borders
- restrained gray fills
- compact black labels
- system/Geist-like sans typography
- monospace for type signatures
- generous whitespace
- no gradients
- no glassmorphism
- no decorative AI imagery

Suggested tokens:

```css
:root {
  --bg: #fff;
  --fg: #0a0a0a;
  --muted: #666;
  --subtle: #8f8f8f;
  --line: #eaeaea;
  --soft: #fafafa;
  --soft2: #f5f5f5;
  --good: #0070f3;
  --warn: #9a6700;
  --bad: #d93025;
}
```

Use:

```css
font-family:
  Geist,
  "Geist Sans",
  ui-sans-serif,
  -apple-system,
  BlinkMacSystemFont,
  "Segoe UI",
  sans-serif;
```

Monospace:

```css
font-family:
  "Geist Mono",
  "SFMono-Regular",
  Consolas,
  monospace;
```

---

# Layout

Recommended:

```text
Header
Type-system map
Type-information gradient
Candidate 01
Candidate 02
Candidate 03
Top recommendation
```

Max content width ~1180px.

Use top borders and whitespace rather than giant rounded cards.

---

# Candidate Visual

Each candidate should include a large before/after type diagram.

Example:

```text
BEFORE                               AFTER

Tool                                 Tool
│                                    ├─ associatedtype Input
├─ execute(Any) -> Any               ├─ associatedtype Output
│                                    └─ execute(Input) -> Output
└─ caller casts result
```

Under the diagram, show:

```text
COMPILER GAIN
Wrong input/output combinations stop compiling.

API GAIN
Callers no longer cast.

COMPLEXITY COST
Generic relationship must propagate through ToolRunner.

WHY NOT SIMPLER?
An enum does not fit because Tool is an open extension point.
```

---

# Type Information Gradient

Use a horizontal or vertical diagram:

```text
STATIC RELATIONSHIP                                      RUNTIME FLEXIBILITY

Concrete → T: P → some P → any P<Constraint> → any P → Any
```

Add a caption:

```text
This is a design continuum, not a ranking.
```

Do not imply `some` is always better than `any`.

---

# Tier Badges

Tier 1:

```text
TIER 1 / CLEAR COMPILER WIN
```

Tier 2:

```text
TIER 2 / ARCHITECTURAL TYPE WIN
```

Tier 3:

```text
TIER 3 / ADVANCED
```

Tier 3 cards should visually show higher scrutiny.

---

# Score Strip

Show:

```text
COMPILER GAIN 5/5
TYPE INFO 5/5
API CLARITY 4/5
LOCALITY 4/5
COMPLEXITY COST 2/5
RISK 3/5
```

Remember:

- higher complexity cost is worse
- higher risk is worse

Do not calculate a total score.

---

# Evidence

Use real repository names.

Good:

```text
FILES
Sources/RVEngine/PatternEngine.swift
Sources/RVEngine/RuleEvaluator.swift

TYPES
PatternEngine
RuleEvaluator
RuleMatch
```

Bad:

```text
several files
core types
```

---

# Compiler Gain Panel

Make this one of the strongest visual elements.

Use exact before/after failure semantics.

Example:

```text
BEFORE
registry.register(parser: any Parser, output: Any.Type)
→ mismatch detected at runtime

AFTER
registry.register<P: Parser>(_ parser: P)
→ P.Output preserved statically
→ wrong result type does not compile
```

---

# Complexity Cost Panel

Never omit this.

The report must make advanced Swift look costly when it is costly.

Possible costs:

- generic parameter propagation
- additional `where` clauses
- existential boundary complexity
- source compatibility
- ABI implications
- compiler diagnostic complexity
- build-time specialization
- reduced dynamic flexibility

This prevents "generics because generics."

---

# Diagnostic Quality

Include one short note per candidate:

```text
DIAGNOSTICS

Today:
runtime cast failure in RuleRunner

After:
compiler points to mismatched Tool.Input at call site
```

or, when worse:

```text
DIAGNOSTICS

Cost:
same-type constraints produce harder-to-read errors across three layers
```

A refactor that improves runtime safety but badly degrades diagnostics should be treated with caution.

---

# Top Recommendation

End with one candidate:

```text
TOP RECOMMENDATION

01 / Preserve Tool input/output relationships

Why:
Eliminates runtime casts across the central execution path while keeping
heterogeneity at the registry boundary.

Main question:
Can the erased registry boundary stay package-internal?
```

Do not start implementation.


# Genericity Spread

Every candidate must show how far generic parameters, associated types, or constraints propagate.

Example:

```text
LOCAL
Parser.swift → ParserRunner.swift
```

or:

```text
WIDE
Domain → Engine → CLI → tests
```

Wide propagation is a major cost and must be justified.

# Compatibility

For every candidate, state whether it affects:

- public API
- external conformers
- source compatibility
- ABI/library evolution
- serialization/persistence
- deployment/toolchain requirements

# Diagnostic Quality

Include one short diagnostic-quality note per candidate.

Example:

```text
DIAGNOSTICS

Before:
runtime cast failure in RuleRunner

After:
compiler points to mismatched Tool.Input at call site
```

Or, when worse:

```text
DIAGNOSTICS

Cost:
same-type constraints create harder-to-read errors across three layers
```

A refactor that improves runtime safety but badly degrades diagnostics should be treated with caution.
