Paste this entire file as the first message of a new session in `/Users/chriskarani/CodingProjects/rv`. Do not summarize it first. Implement. Do not re-plan.

---

You are implementing the locked **product takes** program in this repo only. The previous session compared pinned 0.11.0 upstream to rv, chose three remaining takes, and wrote the spec + plan. **Implementation has not started.** Unwrap is already shipped — verify it, do not rebuild it.

**This human message names this program.** Do not start OPE-156, Host Ask, or anything else on `docs/architecture/02.md` § Order. Do not sit on `fix/install-real-download-progress` — that branch is unrelated. Create / switch to `feat/product-takes` from current `main` (or a worktree of `main`). Keep the currently untracked planning files; do not stash them away.

Read in this order, then code. Do not re-derive acceptance:

1. `AGENTS.md`
2. `spec/spec-architecture-product-takes.md` — **wins** APIs, REQs, AC
3. `planning/2026-08-31-product-takes-implementable-program.md` — **wins** waves, exclusive-writes, algorithms
4. `planning/2026-08-31-product-takes/HANDOFF.md`

Skills before coding: `.grok/skills/swift-feature-implementation`. Then per wave: W1 `.grok/skills/swift-hook-xpc`; W2 `.grok/skills/swift-hexagonal-spm` + `.grok/skills/swift-evaluate-parity`; W3 `.grok/skills/swift-evaluate-parity`. Do **not** load `thermo-nuclear-code-quality-review`.

Gate: `tools/gate.sh` via `tools/swift-6.3.3`. Keep `.build` warm. Do not `swift package clean`. Swift Testing only. No live HOME. No `try!` / `!` on production paths. Value types in Domain/Engine/Packs/Presentation. Do not commit unless I ask.

If you are unsure about a string, file, or order, open the spec and copy it. Do not guess.

---

## What to ship (three waves)

### Wave W1 — unwrap proof + hook deny tip

**T1 / w1-unwrap-verify (verify_only):** Run `tools/gate.sh RVEngineTests RVServiceTests`. If unwrap / wrapper / semantics tests are green, **do not edit** `Sources/RVEngine/Unwrap.swift`. No heredoc/AST.

**T2 / w1-deny-why:** Change `hostDenyWhy` / `hostDenyLine` in `Sources/RVHooks/HostDenyText.swift` so sentence 2 of the pack reason survives (REQ-020–028).

Canonical reset-hard line (one line, no command echo, no `allow-once`):

```text
RV · Blocked. Destroys uncommitted changes. Use 'git stash' first.
```

Algorithm (copy from the plan):

1. Trim `reason`.
2. Strip command preview prefix (existing).
3. Split on first `. `. Left = sentence 1. Remainder = rest.
4. Sentence 2 = rest up to next `. ` or EOL; drop further sentences.
5. Capitalize sentence 1 as today; both sentences end with `.`.
6. Omit sentence 2 if empty, or if it contains `allow-once`, `ALLOW-`, `redeem`, `RV_BYPASS`, or a newline; or if the full line would contain U+001B, `═`, `┌`, or a newline; or if sentence 1 + sentence 2 together exceed **180** Unicode scalars after `RV · Blocked. `.
7. Return `RV · Blocked. \(s1)` or `RV · Blocked. \(s1) \(s2)`.

Do **not** import `RVPresentation`. Do **not** call `suggestions(for:)`. Do **not** change `hostAskLine` / `hookUnlockNext`. Allow stays silent. Indeterminate stays `incompleteEvalSentence`.

In `Tests/RVHooksTests/HostDenyTextTests.swift`: set `resetHardHostDeny` to the new canonical string. `assertHookDenyHasNoBypassOrEssay` must **stop** forbidding `git stash`. It must still forbid `allow-once`, `Terminal`, `git reset --hard` as command echo, boxes, ANSI, redeem. Keep forbidding `reset --soft` (that is TTY essay, not the pack second sentence).

**T3 / w1-deny-fixtures (after T2):** Update every honor-path golden listed in spec T3 exclusive-writes, including `tools/c-hook-proof.sh` `CANONICAL` and `docs/factory/references/host-contracts-v1.md`. Then `tools/c-hook-proof.sh` must pass.

W1 prove:

```sh
tools/gate.sh RVEngineTests RVServiceTests
tools/gate.sh RVHooksTests
tools/c-hook-proof.sh
tools/gate.sh RVCLITests RVTUITests
```

### Wave W2 — `system.disk` day-one

**Only** add `system.disk` to the default set. Do not enable any other pack.

**T4 / w2-algebra:**

- `dayOnePackIDs` = `core.filesystem`, `core.git`, `system.disk` (sorted by `rawValue` — already that order).
- Add `PackID.systemDisk`.
- `PackSet.defaultIDs` **is** `dayOnePackIDs` (delete the second literal list).
- `PackRegistry.loadDayOne` loads `dayOnePackIDs.map(\.rawValue)`, not a hardcoded two-name array.
- `system.disk.json` `"enabled_by_default": true`.
- `index.json` `"default_enabled"` includes `system.disk`.

Update tests that go red immediately: `Tests/RVDomainTests/NewtypeTests.swift`, `Tests/RVPacksTests/EnablementTests.swift`, `Tests/RVPacksTests/PackLoadTests.swift`.

Known cardinality updates:

- `enablement_defaultsAreCoreOnly`: set **includes** `system.disk`, still excludes postgres/docker. Rename the test if “CoreOnly” becomes a lie; behavior is three day-one ids.
- `enablement_k8sCategoryAddsThreePlusCore`: `raw.count` **6**.
- `enablement_presetMembershipDropsWindowsOSPacks`: 33 → **34** (one more default).

**T5 / w2-tests-docs (after T4, do not re-edit T4 files):**

- Doctor: `Sources/RVService/DoctorSnapshotBuilder.swift` must not keep `"core.git and core.filesystem loaded"`. List all three ids.
- `CONTEXT.md` Day-one packs; `docs/dev/PARITY.md`; `docs/factory/specs/phase-4-later.md` disk-default row superseded **for disk only**; remaining catalog still later. `docs/architecture/MODULES.md` / `MAP.md` if they still say two day-one packs.
- Corpus: REQ-048 — deny `mkfs.ext4 /dev/disk0` (or first matching destructive pattern in `system.disk.json`); deny `dd if=/dev/zero of=/dev/rdisk0 bs=1m`; allow `dd if=/dev/zero of=./out.bin`; allow `lsblk` / `df` / `mount` with no args.
- Hunt remaining complete-set literals: `rg "core.git and core.filesystem"` and `["core.filesystem", "core.git"]` as **the full day-one set**. Prefer `dayOnePackIDs` in tests.
- Operator can still `rv packs disable system.disk`. Empty config `enabled` still means no extras; defaults still union. Do not change empty-`enabledPacks` on the **request** field.

W2 prove:

```sh
tools/gate.sh RVDomainTests RVPacksTests RVCorpusTests RVServiceTests RVCLITests RVPresentationTests RVAnalyticsTests
```

### Wave W3 — rebase recovery (security-sensitive)

Do this last. **Never** auto-allow `git reset --hard` / `git reset --merge` / `git clean -f` / force-push, even when rebase dirs exist.

**T6 / w3-eligible-gate:** New `Sources/RVPolicy/RebaseRecovery.swift`. Pure `RebaseRecovery.isEligible(result:) -> Bool`. New `PolicyOverride.rebaseRecovery`. `PolicyGate.decide` gains `rebaseInProgress: Bool = false`.

Deny-branch order (REQ-065):

1. if `rebaseInProgress && isEligible` → allow + `.rebaseRecovery`
2. else if `RulePinning.blocksAllowOverride` → stay deny
3. allowlist
4. allow-once

Rebase recovery **must** run before the working-tree-discard pin. It must **not** call `AllowOnceStore.consume` or `HostGrantWriter.plantAndSpend`. Pass `rebaseInProgress` through `apply` / `peek` / `spendHostAllowOnce`. Default `false` so existing tests keep compiling.

Eligibility (REQ-060–063): deny; not `reset-hard` / `reset-merge` / `clean-force` / `push-force-*`; innermost `GitAction` is `.discardWorktree` or `.restore` with `worktree == true`; **or** `gitAction` nil and pack rule is `checkout-discard` / `checkout-ref-discard` / `restore-worktree` / `restore-worktree-explicit`. `builtin.action:working-tree-discard` is eligible **only** via the GitAction check, never by builtin id alone.

No `FileManager` in RVPolicy.

**T7 / w3-probe:** New `Sources/RVService/GitRebaseProbe.swift` next to `FilesystemLiveProbe`. Reuse `discoverRepositoryRoot`. Nil cwd → false. No repo root → false. `.git` directory → that path. `.git` file → parse one `gitdir:` line; relative paths resolve against repo; parse fail → false. True iff `gitdir/rebase-merge` or `gitdir/rebase-apply` exists **and** is a directory. `GatedEvaluate` after `evaluateWithSemantics`, before PolicyGate: `GitRebaseProbe.rebaseInProgress(cwd:)` into `decide`/`apply`/`peek`. Do not walk HOME. Do not use process cwd when hook cwd is nil.

**T8 / w3-service-tests:** New `Tests/RVServiceTests/GatedEvaluateRebaseRecoveryTests.swift`. Temp dirs only. Create `.git/rebase-merge/` (no real `git rebase`). All seven REQ-069 cases.

W3 prove:

```sh
tools/gate.sh RVPolicyTests
tools/gate.sh RVServiceTests
```

---

## Hard reject list

- `RV_BYPASS` or any env the hook child honors to skip evaluate
- Allow because XPC missed
- Redeemable allow-once code on hook deny / fixtures
- Box drawing / ANSI / newlines on hook deny
- Import `RVPresentation` from `RVHooks` or `RVPolicy`
- `FileManager` / `Date()` inside `RVEngine.evaluate`
- Full heredoc/AST
- Enabling packs other than adding `system.disk` to day-one
- Named stack preset
- `rv rebase-recover` / `.rv/rebase-recovery-permit`
- Host Ask / ApprovalBridge / changing `Decision`
- Treating `builtin.action:working-tree-discard` as rebase-eligible without `GitAction`
- Reimplementing `Unwrap.swift` when T1 gates are green
- Foreign product names in `install.sh` / README hero / adapter user strings
- Live-HOME tests

---

## Parallelism

T1 ∥ T2 ∥ T4 ∥ T6. T3 after T2. T5 after T4. T7 after T6. T8 after T7. Do not overlap T2 and T3 on `HostDenyText.swift` / `HostDenyTextTests.swift`. Prefer serial in one session: W1 then W2 then W3.

If I said “W1 only” / “W2 only” / “W3 only”, stop at that wave’s prove boxes.

---

## Prove when the program is done

- [ ] `uname -m` is arm64; using `tools/swift-6.3.3` / `tools/gate.sh`
- [ ] Unwrap / wrapper tests green **without** a product edit to `Unwrap.swift` (or only a gap-fill if a gate was red)
- [ ] `hostDenyText` for reset-hard is exactly `RV · Blocked. Destroys uncommitted changes. Use 'git stash' first.`
- [ ] That line is one line; no `allow-once`, no `Terminal`, no `git reset --hard` echo, no `═` / ANSI / newline
- [ ] `assertHookDenyHasNoBypassOrEssay` no longer forbids `git stash`
- [ ] `tools/c-hook-proof.sh` PASS
- [ ] `rg -n "RV · Blocked. Destroys uncommitted changes[^\.]" Tests Sources tools docs/factory/references/host-contracts-v1.md` has no honor-path hits (stash clause present)
- [ ] `dayOnePackIDs` / `loadDayOne` / `PackSet.defaultIDs` / `index.json` `default_enabled` / `system.disk.json` `enabled_by_default` agree on three ids
- [ ] Defaults include `system.disk`; exclude `database.postgresql` and `containers.docker`
- [ ] Disk corpus: mkfs/device-dd deny; file `dd` allow
- [ ] Doctor message lists three ids (no leftover `"core.git and core.filesystem loaded"`)
- [ ] Temp `.git/rebase-merge/`: `git checkout -- file` allows with `rebaseRecovery`; `git reset --hard` still denies
- [ ] Same checkout without rebase dirs still denies
- [ ] Worktree `gitdir:` file case allows checkout --; nil cwd does not
- [ ] `git restore --staged` still denies during rebase
- [ ] `rg -n "RV_BYPASS" Sources` is empty
- [ ] `docs/architecture/02.md` execute queue was not rewritten
- [ ] Touched-module `tools/gate.sh` green

If a prove item fails, fix it and re-run that prove. Do not start Host Ask. Do not git commit unless I asked.

When every box is proven, write one short human paragraph: what changed for a user who hits a block in Pi/Grok/OpenCode, that disk wipe is now on by default, that rebase discards can proceed while `reset --hard` cannot, and that Ask is still later. Do not claim OS-enforced / Seatbelt. Do not claim Windows or extra hosts.
