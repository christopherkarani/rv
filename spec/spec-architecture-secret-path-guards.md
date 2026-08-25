---
title: Secret-path guards — operand table on the allow path
version: 1.0
date_created: 2026-08-25
last_updated: 2026-08-25
owner: rv
tags:
  - architecture
  - design
  - engine
  - evaluate
---

# Introduction

This specification adds a **secret-path guard** to `evaluate`. Day-one ICU packs deny destructive git and filesystem verbs. They do not treat `cat .env` as a path read. Quick-reject skips ICU when no pack keyword appears, so that command is allow today. Catalog `secrets.*` packs cover cloud secret-manager CLIs and stay default-off.

The guard tokenizes the matching view, treats operands as path candidates, and matches a closed Domain table. It runs only when the 0.11.0 pack walk would allow. Pack deny `rule_id`s do not change. Evaluate stays pure. Matching view stays T1-normalized submitted text.

# 1. Purpose & Scope

## Purpose

Deny content access to a closed set of local secret paths when a shell operand names them. Keep `echo .env` allow. Keep `rm -rf ~/.ssh` on its filesystem `rule_id`.

## Audience

Implementers of rv (Swift 6.3.3, macOS 26, Apple Silicon) and reviewers using the evaluate-parity skill.

## In scope

- `SecretPathCatalog` in RVDomain and a pure operand walker in RVEngine.
- Fold on the pack-allow path, including quick-reject allow.
- Virtual `PackID.coreSecrets` for `RuleID` only. Not a catalog pack. Not a third day-one ICU pack.
- Corpus rows in `deny.json` and `near-miss.json`. Not `skill-table.json`.
- Vocabulary in `CONTEXT.md`. One-line notes in `MODULES.md` / `MAP.md`.

## Out of scope

- Nested unwrap, interpreter `open('.env')`, base64 path decode.
- `FileManager`, `realpath`, `ProcessInfo`, expanding `~` into the matching view.
- `EvaluationRequest` home/cwd fields. IPC bump.
- Git control-plane guards. Policy self-protection.
- Read / Edit / MCP. Custom denyPaths / allowPaths.
- Coding-CLI config files (`settings.json`, `mcp.json`). Public-key exemption inside `.ssh`.
- New `ExplainStep` case. Secret-path deny projects as existing `destructive` via `Deny.ruleID`.
- Enabling catalog `secrets.*` by default. Changing `corePacksAreReady`.
- `RV_BYPASS`. Seatbelt. Live-HOME tests.

## Assumptions

- T0–T9 and the C-hook pipe are done. `evaluate` is pure. Policy gate fingerprints matching view plus cwd.
- Day-one ICU packs remain `core.git` and `core.filesystem`.
- Allow-once already unlocks a deny for that matching view and cwd.
- PLAN wins product-law conflicts.

## Intended audience constraints

A test that needs a TTY to prove a **decision** is in the wrong module. Secret-path deny/allow is proven in `RVEngineTests` / `RVCorpusTests`.

# 2. Definitions

| Term | Meaning |
|---|---|
| **Secret-path guard** | Pure scan of path-shaped operands on the T1 matching view against `SecretPathCatalog`. |
| **Secret-path catalog** | Closed list of `SecretPathRule` values passed into `evaluate`. `.dayOne` is production. `.empty` disables the guard. |
| **Path candidate** | A decoded token (or `--flag=value` suffix) the extractor treats as a possible filesystem path. |
| **Non-path head** | argv0 basename `echo` or `printf` (ASCII case-insensitive, trailing path stripped like Normalize argv0). These heads contribute no candidates. |
| **Allow path** | Pack walk produced allow: `.quickRejected`, `.plain`, `.safeOnly`, or `.hit`. Not deny. Not indeterminate. |
| **Virtual pack** | `PackID.coreSecrets` (`core.secrets`). Exists for `RuleID` construction. Not in `dayOnePackIDs`, not in `index.json`, not compiled by ICU. |

# 3. Requirements

### Constraints

- **CON-001**: `evaluate` stays pure. No `Date()`, `FileManager`, `ProcessInfo`, network, or path `stat`.
- **CON-002**: `RVEngine` does not import `RVPacks`.
- **CON-003**: Matching view stays T1-normalized submitted text. The guard reads it. It does not rewrite it.
- **CON-004**: Existing 0.11.0 pack deny `rule_id`s stay. The guard runs only on the allow path.
- **CON-005**: Empty / oversize / `corePacksUnavailable` / `budgetExhausted` outcomes are unchanged and do not run the guard.
- **CON-006**: `dayOnePackIDs` remains `[core.filesystem, core.git]`. `corePacksAreReady` still requires those two ICU packs only.
- **CON-007**: No live-HOME tests. No command text in `os_log`.

### Requirements

- **REQ-001**: Add `PackID.coreSecrets` with `rawValue` `core.secrets`.
- **REQ-002**: Add `SecretPathKind` and `SecretPathRule` in RVDomain. A rule has `pattern` (RuleID pattern token), `kind`, and `reason`.
- **REQ-003**: Add `SecretPathCatalog` with `rules: [SecretPathRule]`, `static let empty`, `static let dayOne`.
- **REQ-004**: `evaluate` takes `secrets: SecretPathCatalog = .dayOne` after `packs`. Call sites may omit it.
- **REQ-005**: After normalize, if the pack walk (including the quick-reject skip that returns `.quickRejected`) would allow, run `SecretPathGuard.firstHit(in:catalog:)`. A hit becomes `.deny(Deny(ruleID:matched.ruleID, reason:matched.reason), matched:)` with `severity` `.high`. `regex` is nil. `searchText` is the matching view. `matchedText` is the candidate that hit.
- **REQ-006**: If the pack walk denies or is indeterminate, return that result. Do not run the guard.
- **REQ-007**: `.empty` catalog makes `evaluate` identical to pre-guard behavior for the same request, packs, and compiled patterns.
- **REQ-008**: Reuse `tokenizeCommand` on each `splitSegments` piece and on the full matching view, same segment-then-full order as packs. First hit wins. Cap candidates at 64 per haystack. Extra tokens are ignored, not indeterminate.
- **REQ-009**: Non-path heads `echo` and `printf` yield no candidates for that segment.
- **REQ-010**: Tokens starting with `-` are not candidates unless they contain `=` after the first character. The substring after the first `=` is a candidate (`dd if=.env`, `--file=.env`). `--` is not a candidate.
- **REQ-011**: Head `grep` or `rg` (basename, case-insensitive): the first positional is not a candidate unless a path-supply flag already appeared (`-e`, `-f`, `--regexp`, `--file`, `--files`, including clustered shorts that contain `e` or `f` among option letters). `-f` / `--file` values are candidates. `rg --files` treats remaining positionals as candidates.
- **REQ-012**: Head `find`: tokens before the first predicate (`token.hasPrefix("-")`, `(`, `!`, `;`) are candidates. `-name` / `-iname` / `-path` values are not candidates.
- **REQ-013**: Other heads: every remaining decoded positional is a candidate.
- **REQ-014**: Match a candidate against `dayOne` rules in table order. First hit wins.
  - **basename**: last `/`-separated component equals the name.
  - **envVariant**: last component starts with `.env.` and is not an exemption (`.env.example`, `.env.sample`, `.env.template`, `.env.defaults`, or prefix `.env.example.` / `.env.sample.`).
  - **homeSuffix**: candidate has prefix `~/` + joined parts, or `$HOME/` / `${HOME}/` + joined parts, or `/`-split components contain the suffix parts as a contiguous tail or interior sequence.
  - **hostAuth**: same as homeSuffix for the listed suffix parts.
- **REQ-015**: `dayOne` rows, in this order, with shared reason `Access to a sensitive path is not allowed.` unless noted:

  | pattern | kind |
  |---|---|
  | `env` | basename `.env` |
  | `env-variant` | envVariant |
  | `npmrc` | basename `.npmrc` |
  | `pypirc` | basename `.pypirc` |
  | `netrc` | basename `.netrc` |
  | `git-credentials` | basename `.git-credentials` |
  | `id-rsa` | basename `id_rsa` |
  | `id-ed25519` | basename `id_ed25519` |
  | `id-ecdsa` | basename `id_ecdsa` |
  | `credentials` | basename `credentials` |
  | `home-ssh` | homeSuffix `[".ssh"]` |
  | `home-aws` | homeSuffix `[".aws"]` |
  | `home-gcp` | homeSuffix `[".gcp"]` |
  | `home-gcloud` | homeSuffix `[".config", "gcloud"]` |
  | `home-kube` | homeSuffix `[".kube", "config"]` |
  | `home-docker` | homeSuffix `[".docker", "config.json"]` |
  | `host-pi-auth` | hostAuth `[".pi", "agent", "auth.json"]` |
  | `host-grok-auth` | hostAuth `[".grok", "auth.json"]` |
  | `host-opencode-auth` | hostAuth `[".local", "share", "opencode", "auth.json"]` |

- **REQ-016**: `RuleID.rawValue` is `core.secrets:<pattern>`.
- **REQ-017**: Must deny: `cat .env`, `xxd .env`, `cat ~/.ssh/id_rsa`, `dd if=.env of=/tmp/x`, `rg --files ~/.ssh`, `grep -f .env pattern`, `cat ~/.pi/agent/auth.json`. Also deny `rm .env` with `core.secrets:env` when filesystem ICU does not already deny that line.
- **REQ-018**: Must allow: `echo .env`, `printf .env`, `cat .gitignore`, `cat .env.example`, `find . -name .env`, `rg .env` (pattern-only), `grep .env README.md`, `git status`, `git reset --hard` still `core.git:reset-hard`, `rm -rf ~/.ssh` still a `core.filesystem` deny id (not `core.secrets:home-ssh`).
- **REQ-019**: Guard comparisons do not increment `EvaluationBudget.maxPatternAttempts`.
- **REQ-020**: `explainSteps` needs no new case. A secret-path deny uses the existing deny projection (`destructive` = `core.secrets:<pattern>`).

### Guidelines

- **GUD-001**: Keep `SecretPathGuard` one file. Do not add a protocol.
- **GUD-002**: Prefer table-driven Engine tests plus a few corpus rows. Do not duplicate every table row in `deny.json`.
- **GUD-003**: Do not add `Suggestions.swift` entries in this ticket.

# 4. Evaluation order (updated)

Raw gates (empty, oversize, core packs) unchanged.

Then: normalize → pack quick-reject / safe / destructive (unchanged) → **secret-path on allow** → default allow.

# 5. Proof

```
tools/swift-6.3.3 --version   # Apple Swift version 6.3.3
tools/gate.sh --quiet RVDomainTests RVEngineTests RVCorpusTests
```

# 6. Non-goals reminder

Do not fold this into `core.filesystem.json`. Do not put `.env` regexes in `secrets.aws_secrets`. Do not deny from `PolicyGate` (it does not run on allow).
