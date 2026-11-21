# Anti-Slop Lane Criteria

Use this when the `aislop` / `ai-slop` / `anti-slop` skill is not installed.
If one of those skills exists under `.claude/skills/`, prefer its body and treat
this file as a fallback checklist.

## Mission

Detect and demand removal of **AI slop**: text and code patterns typical of
unreviewed LLM output that add noise without value, fake structure, or
premature abstraction.

## Flag aggressively

### Code

- Comment restating the next line (`// increment counter` above `i += 1`)
- Narrating comments / section banners that do not encode non-obvious intent
- Dead code, unused imports, placeholder stubs left “for later”
- Over-abstracted helpers used once (identity wrappers, pass-through facades)
- Boilerplate error handling that swallows or rewraps without adding context
- Defensive null-checks for invariants the type system already guarantees
- Copy-pasted blocks with trivial renames instead of a shared helper
- “Enterprise” layering (interfaces, factories, DI) with a single implementation
  and no seam requirement
- Chatty logging / debug leftovers
- Speculative configuration flags for features not in the change
- TODO/FIXME without owner or issue reference when they block clarity
- Markdown or docs walls inside code reviews that restate the diff

### Prose in code / docs / commits (when in scope)

- Filler openers: “In order to…”, “It is important to note…”, “This ensures that…”
- Vague claims without evidence: “robust”, “seamless”, “comprehensive”, “production-ready”
- Bullet lists that restate headings without new information
- Fake precision: numbered steps for a 2-line idea
- Hedging piles: “might potentially possibly”
- Emoji decoration in engineering artifacts (unless project norm)
- Changelog-style padding in PR/plan text unrelated to the actual change

### Structure smells

- New files that only re-export or rename
- Symmetric “before/after” helper pairs that differ by one flag
- Test names or tests that assert mocks rather than behavior
- Snapshot/golden noise without asserting the invariant that matters

## Do not flag

- Concise non-obvious intent comments
- Required license headers or project-mandated banners
- Necessary trait/interface boundaries with multiple impls or testing seams
- Explicit error context that aids operators
- Domain vocabulary that looks “wordy” but is the ubiquitous language

## Preferred remedies

- Delete the slop first; only then rewrite
- Inline one-shot helpers
- Replace restating comments with better names
- Collapse speculative layers
- Make tests assert observable behavior
- Prefer the boring direct implementation

## Output bias

Prefer fewer high-signal slop findings over a laundry list of nits.
Severity: most pure-slop is **minor**; slop that hides a bug or security issue
upgrades with the underlying issue’s severity.
