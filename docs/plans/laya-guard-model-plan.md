# Plan: destructive-command guard modeled on laya-guard (Laya judge in rvd)

Goal: rv judges every ambiguous tool call the way
[laya-guard](https://github.com/scs0209/laya-guard) does, in laya-guard order: packs,
safe lane, judge as allow / review / block with a numeric risk
score. The model is the centerpiece, not an optional extra. The packs can
only raise its verdict, never lower it.

Owner decisions (2026-10-19):
- Safe-command lane included (added 2026-10-19 after benchmarks showed
  the model wrongly stopping 16/35 benign shell commands): packs first,
  proven-safe single commands skip the judge (laya-guard allowlist +
  `swift build|test`), installs/pushes/secret paths never enter.
- One guard posture switch, `guard.mode`: `enforce` (shipped default —
  packs deny as today) or `observe` (packs and judge both evaluate and
  log the would-be verdict; nothing blocks). Observe is the trial mode
  for the whole guard, not a model-only shadow.
- The judge runs whenever a weights bundle is installed. It binds in
  enforce mode and only logs in observe mode. No bundle means packs-only
  operation, reported by `rv doctor`.

Status: plan only. No code changes. Rewritten 2026-10-19 around two existing
ports that remove the Python/PyTorch blocker:

- macOS: [mizorewww/laya-coreml](https://github.com/mizorewww/laya-coreml) —
  Core ML bundles with tokenizer, config, checksums, packaging validation.
- Linux: [receptron/laya](https://github.com/receptron/laya) — ONNX bundle
  plus `export/export_onnx.py` to build our own from the upstream checkpoint.

## How laya-guard judges (the model to copy)

```
tool_call → hook → judge
  → chains split at top-level ; && || & , worst verdict wins
  → policy.yaml: 12 regex policies
      block match  → instant block (risk 0.92, model not consulted)
      review match → model judges, floor is review (risk ≥ 0.55)
      safe command → instant allow (risk 0.05; npm/pnpm/yarn/bun scripts it
                     would run are regex-checked first)
      else         → Laya judges freely
  → Laya `Router.predict(text, questions, model="multilingual")`, 3 questions:
      action    = choice  allow / review / block   (probabilities returned)
      risk      = score   safe / caution / danger
      malicious = noul    malicious or instruction-hijack
  → risk = P(block) + 0.5·P(review), then max(risk, malicious), clamped 0–1
  → block ≥ 0.80, review ≥ 0.45 (tool/email/web sources: 0.60 / 0.30)
```

Laya itself: non-autoregressive encoder, one forward pass, no generated text.
Checkpoints (Convai Innovations, Apache-2.0): multilingual mmBERT-base 322M,
1,024 tokens; English ModernBERT-large 421M, 512 tokens ("best at
guardrails"); typed-decisions 421M. Input >4K chars is windowed, worst window
wins; >256K chars blocked unread. Model failure falls back to
regex+heuristics. Verdict log stores action/risk/policy/latency/truncated
SHA-256, never command text.

## The two ports (verified facts, with the caveats that bind us)

| | laya-coreml | receptron/laya (ONNX) |
| --- | --- | --- |
| General bundle rv uses | Multilingual 322M, 1,024 tok, CPU+GPU; English 421M, 512 tok | `laya.onnx` + `.data` + `laya_config.json` + `tokenizer/tokenizer.json` |
| Headline number to ignore | ~5 ms is the ANE L96 bundle: 96-token total budget incl. question+options. Unusable for judging real commands | ~140 ms warm for 3 questions is via Node on Apple-silicon CPU; Linux x86_64 number is ours to measure |
| Fidelity evidence | 189/189 selected answers match upstream; ANE FP16 max probability drift 0.0029; W8 palette 0.0144 under a 0.02 gate. Conversion fidelity, not task accuracy (their wording) | Output matches Python to 4 decimal places; export script prints max logit diff vs PyTorch (~1e-5) |
| Size | FP16 bundles (exact bytes: Phase 1 measures) | ~1.7 GB fp32 weights, ~2 GB RAM loaded. Quantization required before shipping (Phase 3) |
| Runtime deps at inference | None (no torch/transformers/MLX) | ONNX Runtime only |
| API | Python wrapper over Core ML — not a Swift package | TypeScript wrapper — not usable from Swift directly |
| First init | Tens of seconds (Core ML compilation) | Model load + session create |

Both ports clamp fitted calibration temperatures to `[0.5, 5.0]`: the raw
checkpoint ships 0.1006 for one choice bucket, which would report a coin flip
as near-certainty. Any rv host implementation must apply the same clamp and
surface clamped buckets in diagnostics. Token formatting must byte-match
upstream (the ONNX port serializes JSON state Python-style for this reason);
silent token drift = silently wrong probabilities.

## Verified ground truth in rv (do not re-derive, do not regress)

- Deterministic layer is already stronger than laya-guard's 12 regexes:
  96 pack JSONs, `RVEngine.evaluateWithSemantics` (unwrap/peel, git/fs
  semantic analyzers, chain split with worst-wins), `SecretPathGuard`.
  Pack deny is a floor; semantics only tighten. This is part 1 of 2.
- Verdict plumbing exists: pack-door `Decision` is never Ask
  ([Decision.swift](/Users/chriskarani/CodingProjects/rv/Sources/RVDomain/Decision.swift));
  Ask is minted at the hook door by `HookAuthorization`
  (`allow`/`ask`/`denyPinned`) plus `PolicyGate` (allowlist, allow-once,
  rebase recovery). Laya's `review` maps to rv's `ask`. No new verdict type.
- Floors exist: `HardPolicyDecision` zones `hardAllow` / `hardDeny` /
  `mandatoryHuman` / `reviewEligible(fallback:)`. The Laya judge runs in
  `reviewEligible` and in the review-floor cases below.
- The current model adds zero live protection:
  [FoundationModelsActionReviewer.swift](/Users/chriskarani/CodingProjects/rv/Sources/RVPolicy/FoundationModelsActionReviewer.swift)
  is shadow-only via `ShadowReviewRunner`, referenced only inside `RVPolicy`,
  categorical (`allow/deny/abstain` + `RiskLevel` + self-reported
  confidence), macOS 26+ only, 3 s timeout, no probabilities. Under this
  plan Apple FM leaves the judge seat entirely; it keeps only generation
  jobs (English policy compilation).
- `rvd` is the warm home: `Sources/RVService/CoreWarmup.swift` already
  pre-compiles packs at daemon start; model load joins that path.
  Owner-authenticated IPC replaces laya-guard's unauthenticated
  `localhost:8787` HTTP (a spoofable allow oracle — explicitly not copied).
- Gaps vs laya-guard today: no numeric risk, no provenance on
  `EvaluationRequest`, no script-expansion check for `npm test` & co.
  (Rv's pack-internal `safe_patterns`, `QuickReject`, and
  `ContainedReversibleDelete` already exist and stay as they are —
  they are part of the packs, not a separate safe lane.)
- Stricter than laya where rv already is: `commandByteCap = 65_536` →
  `indeterminate` → denied. Keep; do not raise toward 256K.

## The two parts and the verdict mapping (definitions used throughout)

| Part | What it is | Can decide |
| --- | --- | --- |
| Packs | Existing packs + `SecretPathGuard` + git/fs semantics in `RVEngine`, including the `package.json` script check (Phase 5) | Pinned deny, block-floor deny, review-floor (Ask) |
| Judge | Warm Laya classifier in `rvd` (CoreML / ONNX) for everything the packs don't settle, plus their review-floor hits | Allow / Ask / unlockable deny via risk thresholds; never a pinned deny |

There is no third part. A command the packs have no opinion on always
reaches the judge — including `ls` and `git status`. That costs a model
call each time and accepts some model mistakes on boring commands.
Phase 1 and observe-mode logs measure that cost honestly; if it
proves too high, a safe list is a later, separate decision (see Risks).

Verdict vocabulary — laya-guard's tri-state maps onto rv's hook door:

| laya-guard | rv | Meaning |
| --- | --- | --- |
| `allow` | Allow | Host runs the call |
| `review` | **Ask** | Human decides: pending-approval row + allow-once code (`HookAuthorization.ask`) |
| `block` | Deny | Unlockable deny, or pinned deny where the packs pin it (no code minted) |

So "review floor" in this plan always means "Ask floor": the judge may
raise it to Deny, never lower it to Allow. Where a host has no real ask
transport, Ask renders per that host's codec — the policy decision never
degrades to Allow.

## Design decisions

1. **Two parts only: packs, then judge.** Packs + semantics first (can
   pin). Everything the packs do not settle goes to the Laya judge, plus
   review-floor pack hits with their Ask floor attached. Each part can
   only raise the other's verdict: packs over judge, provenance over both.
   No safe-command lane in this plan.
2. **Numeric risk is real and gates the verdict** — computed exactly as
   laya-guard does (`P(block) + 0.5·P(review)`, max with `noul`). Starting
   thresholds copy laya-guard's (0.80/0.45; 0.60/0.30 untrusted), then are
   re-derived on rv's corpus in Phase 1/4. They are config, not constants.
3. **One judge API, two runtimes.** New `GuardJudge` surface in `RVDomain`:
   input = sanitized command text + provenance; output = choice
   probabilities, risk score, malicious score, checkpoint ID, latency.
   macOS conformer wraps Core ML; Linux conformer wraps ONNX Runtime's C
   API; both live in `rvd`. `ActionReviewer`/`ActionReview` gain the
   probability fields rather than a parallel type hierarchy.
   Cross-runtime parity is a tested property (drift gate ≤ 0.02 on
   calibrated probabilities over the corpus — the same gate laya-coreml
   publishes; failures block release, not warn).
4. **Self-built weights, pinned.** ONNX bundle is exported by rv's own
   script from the pinned Hugging Face checkpoint (receptron's exporter as
   the starting point), with the logit-diff check in CI. Core ML bundles
   are either converted by the same in-repo pipeline (`laya-coreml[convert]`)
   or fetched with checksum verification against values committed in-repo.
   Checkpoint ID + bundle hash ride in every verdict record. No silent
   "latest" downloads; `rv setup` fetches weights once, shows size + hash,
   and the guard runs fully offline after that. No weights → packs-only
   guard, and `rv doctor` says so loudly (never a silent downgrade).
5. **Checkpoint choice is empirical, not copied.** laya-guard pins
   multilingual because its traffic is Korean-heavy; its own docs say
   English prompts are most of its overblocks. Phase 1 benchmarks English
   421M vs multilingual 322M on rv's shell corpus and picks per evidence.
   The ANE L96 bundles are rejected outright (96-token budget).
6. **Careful tiers overlay the score.** HIGH (pinned: `rm -r` of `/`, `~`,
   `$HOME`; force-push to default branch; `coreSecrets` reads) denies with
   no unlock code regardless of model output — the model is not consulted,
   same as laya-guard's block regexes. MEDIUM (model `review`, or unlockable
   pack deny) asks with reason + allow-once. User/project pattern files are
   additive only and can never lower a floor or a threshold.
7. **Fail-closed on judge failure.** Timeout, load failure, or malformed
   output → `abstain` → `mandatoryHuman` fallback (ask), never allow.
   This is stricter than laya-guard's heuristic stand-in; rv's packs
   already cover what its heuristics approximate.

## Target pipeline

```
hook (8 hosts) / rv test / rv explain → rvd (owner-auth IPC)
  → normalize + peel + segment split               (existing)
  → PACKS + SecretPathGuard + semantics            (existing)
      pinned deny ───────────────────────────────► DENY, no code minted
      block-floor hit ───────────────────────────► DENY (judge skipped)
      package.json script hit ───────────────────► that rule's floor (Phase 5)
      review-floor hit ──► JUDGE, floor = ASK
  → JUDGE Laya (warm in rvd, CoreML | ONNX)        (all remaining calls)
      risk ≥ block-threshold ────────────────────► DENY (unlockable)
      risk ≥ review-threshold or choice=review ──► ASK (allow-once)
      else ──────────────────────────────────────► ALLOW
      abstain / timeout / error ─────────────────► ASK (fallback)
  → provenance (Phase 6): tool/web/email sources use strict thresholds
    and lose contained-reversible allows
```

## Phase 0 — Eval corpus (no behavior change)

- Fixtures under `Tests/RVCorpusTests`: (a) dangerous/bypass shell
  (laya-guard's spellings incl. `sudo`/`xargs`/`sh -c` prefixes, `-exec`,
  escaped `.s\sh`, chains with a poisoned second half), (b) incident
  replays (`rm -rf ~`, `curl | sh`, `cat ~/.ssh/id_rsa`, poisoned
  `npm test`, delete-inside-GraphQL), (c) benign everyday set whose
  overblocking is the cost metric, (d) non-English sample set so the
  multilingual checkpoint gets a fair trial.
- Scorecard runner reports per-case verdict + risk + source (packs or
  judge) + latency.
- Exit: committed scorecard for today's deterministic-only guard.
  Every later phase diffs against it; (a)+(b) holds may not regress.

## Phase 1 — Oracle benchmark: which checkpoint, which thresholds

- Out-of-tree harness (Python `laya-coreml` + receptron ONNX under Node, or
  plain `laya`) runs both checkpoints over the Phase 0 corpus with
  laya-guard's exact three questions (translated criteria identical in
  meaning; the Korean instruction strings are part of the tuned prompt —
  test both original and English renderings, keep whichever measures better
  and record the choice).
- Measure: per-checkpoint hold rate on (a)+(b), overblock rate on (c),
  language split on (d), p50/p95 latency warm on an M-series Mac and on
  Linux x86_64, bundle sizes on disk, RAM resident.
- Sweep thresholds; pick operating points per provenance profile from the
  ROC-ish tradeoff, not from laya-guard's say-so.
- Exit: a decision record (checkpoint, thresholds, prompt strings) with
  numbers. If neither checkpoint beats "ask on everything ambiguous" on
  (c) at equal (a)+(b) holds, stop here and keep the deterministic guard —
  that is a legitimate outcome of this phase, stated in advance.

## Phase 2 — Swift judge host (macOS Core ML first)

- `Sources/RVLaya/` (new target): `LayaJudge` (MLModel load with compile
  cache), tokenizer fed by the bundle's tokenizer files, question/state
  formatting byte-matched to upstream, temperature clamp `[0.5, 5.0]` with
  clamped buckets logged, probability extraction, 4K-char windowing with
  worst-window-wins and truncated-allow→review (mirrors `guard.py`).
- Golden tests: a fixed input set with expected probabilities from the
  Python oracle (Phase 1), asserted within drift ≤ 0.02; tokenizer ID
  sequences asserted byte-for-byte. These tests are the contract; a
  tokenizer mismatch must fail loudly here, not in production verdicts.
- Weights plumbing: `rv setup` downloads the pinned bundle (size + SHA-256
  shown, verified after fetch) into the rv model directory; `rv doctor`
  reports checkpoint, hash, load state. Fully offline thereafter.
- Exit: `rv test --judge 'curl … | sh'` prints choice probabilities + risk
  from the Swift host matching the oracle; no live path wired yet.

## Phase 3 — Linux ONNX conformer + parity

- In-repo export script (from receptron's `export_onnx.py`) builds the
  bundle from the pinned checkpoint; CI asserts max logit diff vs the
  reference at export time. Quantize to fp16 (int8 only if drift gate
  passes) — fp32's ~1.7 GB does not ship.
- Swift wrapper over ONNX Runtime C API (rv already carries C targets;
  follow that pattern), same `GuardJudge` surface, same tokenizer code
  path as Phase 2 where the tokenizer format allows.
- Parity suite: full Phase 0 corpus through both runtimes; verdicts must
  agree, probabilities within ≤ 0.02. Disagreement cases are listed, not
  averaged away.
- Exit: Linux `rv test --judge` parity report green in CI (ubuntu-24.04).

## Phase 4 — Wire into rvd: observe posture + binding in enforce

- Load the judge in `CoreWarmup` alongside packs; daemon reports
  `judge: ready | missing | failed` in doctor snapshots. Cold-start cost
  (tens of seconds for Core ML compile) is paid once at daemon start;
  hooks against a still-warming daemon get deterministic verdicts with
  `verdict_source=deterministic-warming`, never a stall.
- Observe run (`guard.mode: observe`): packs and judge both score every call, the door always allows,
  and every call logs a hash-only would-be row (packs verdict + judge
  choice, risk, checkpoint latency) to `judge-log.jsonl`. Minimum
  sample before calling the judge proven: ≥ 5k judged calls or ≥ 2
  weeks, plus full-corpus green — a reporting bar, not a code gate:
  binding is live in enforce mode from the start (owner decision).
- Evidence bar (reported in the decision record, owner reviews): zero
  judge-allows on later-confirmed destructive commands; overblock on
  corpus (c) ≤ 2%; p95 added hook latency ≤ 150 ms; parity suite green.
- Binding v1: in `reviewEligible`, judge `block` → unlockable deny,
  `review` → ask, `allow` → allow. Review-floor hits: judge can raise
  ask → deny, never lower ask → allow. Pinned and block-floor results
  never reach the judge. Flipping `guard.mode` to `observe` stops all
  blocking instantly (packs included); removing the bundle returns to
  packs-only; `SafetyLevel.strict` raises thresholds one profile.
- Apple FM reviewer is deleted from the judge path at promotion;
  `FoundationModelsEnglishCompiler` (generation) is untouched.

## Phase 5 — Packs look one step deeper: package.json scripts

- `npm|pnpm|yarn|bun test|build|lint|run <name>` with known cwd: check
  `pre<name>`/`<name>`/`post<name>` in the nearest `package.json` against
  the packs (follow nested `npm run` up to 3 deep). This belongs to the
  packs, not the judge: without it the judge sees the words `npm test`
  but never the harmful script hiding inside. A hit takes that rule's
  floor; an unresolvable script graph → Ask floor.
- Scripts are checked against the packs only, never sent to the judge as
  extra input in v1 — the judge judges the command the agent proposed.
- No safe-command lane is built in this phase (owner decision). If the
  observe-mode numbers later justify one, it gets its own plan with a
  list drawn from measured model mistakes, not guesses.

## Phase 6 — Provenance-aware thresholds

- `ActionProvenance` (`userTyped`/`agentPlan`/`toolOutput`/`web`/`email`/
  `unknown`) on `EvaluationRequest`. `unknown` = today's behavior; hosts
  that cannot supply provenance are not silently tightened.
- Untrusted profiles use the strict thresholds from Phase 1, lose
  contained-reversible allows, and cannot be judge-allowed (floor is
  ask). This is the indirect-injection case laya-guard's source profiles
  exist for; MCP door and `rv scan` supply provenance first, hook codecs
  only where a host genuinely provides the signal (live probe per host).

## Phase 7 — Fallback ladder, file tiering, install proof

- Degraded ladder, tested per host codec: full → deterministic-only
  (judge missing/failed/warming) → packs-only → `indeterminate` deny.
  Every degraded verdict carries its `verdict_source`; `rv doctor` shows
  the active rung. A degraded guard is visible, never assumed healthy.
- File-tool tiering parity: credential-path read via file tools → ask
  where the host has a real ask transport (Grok/Claude/Cursor); shell
  reads of the same paths stay pinned; writes to credential paths pinned
  deny; writes to shell-startup / `.git/hooks` / host agent settings →
  ask. `rv scan --suggest` proposes catalog additions, never auto-applies.
- `rv setup` closes with laya-guard's proof step: two synthetic calls
  through each new adapter (one benign, one `git reset --hard`, scratch
  HOME/cwd), observed verdicts reported; judge weights fetch is part of
  the same ceremony with size/hash shown before download.
- Docs: README gains the packs→judge diagram + threshold table;
  `docs/security/runtime-boundary.md` states plainly the guard remains
  hook-grade and the judge is a classifier with measured error rates,
  not a boundary.

## Risks

1. **Tokenizer/formatting drift** silently corrupts probabilities. Mitigated
   by Phase 2 golden ID-sequence tests; this is the most likely way to
   ship a confident wrong judge.
2. **Checkpoint quality on shell text is unproven** until Phase 1. The
   phase has an explicit stop outcome; the deterministic guard must stand
   alone at every point in this plan.
3. **Weights size vs install story.** Even quantized, expect a few hundred
   MB. Setup must ask/show, support offline/air-gapped placement, and the
   deterministic-only rung must remain a first-class supported config.
4. **Two runtimes drift apart** across checkpoint updates. Parity suite is
   a release gate; a checkpoint bump is a deliberate, changelogged event
   with the full corpus re-run on both platforms.
5. **No safe lane has a real cost.** Every everyday command pays a judge
   call (~100 ms class) and can be wrongly asked/blocked — laya-guard's
   own shell set went from 32/50 (model only) to 69/71 (with a safe
   list). Accepted for now to keep the design two-part and simple. The
   Phase 1/4 metrics (overblock rate on benign commands, added p95
   latency) are the agreed trigger to revisit; until then, nobody adds
   ad-hoc safe exceptions outside the packs' existing `safe_patterns`.
6. **Ask fatigue.** A judge that reviews too much trains blanket approval.
   Track ask→approve rate per rule/checkpoint in history; sustained >90%
   approval is a re-tiering signal in `rv scan`, never an auto-change.
7. **Upstream churn.** Laya, both ports, and laya-guard are young,
   single-maintainer-scale projects. Self-built bundles + pinned hashes +
   the deterministic fallback bound the blast radius if any goes stale.

## Decisions (resolved 2026-10-19; remaining)

Resolved: three parts (packs + judge, no safe lane); `guard.mode`
enforce-by-default with observe as the opt-in trial posture; judge on
whenever a bundle is installed (binds in enforce, logs in observe);
laya-guard `review` = rv Ask.

Remaining:

1. Weights distribution: download-at-setup with shown hash (recommended)
   vs bundle in the release tarball (release grows by the quantized size)?
2. Checkpoint after Phase 1 evidence (see decision record): the measured
   model quality on bare shell is weak. Options: fine-tune a checkpoint
   on shell traffic, wrap commands in richer state text, or accept the
   Ask/Deny rates as the cost of the model lane.
