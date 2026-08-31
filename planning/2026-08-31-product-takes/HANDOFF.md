# Handoff — Product takes (deny tip, system.disk default, rebase recovery)

Kind: **planning complete; implementation not started**
Workspace: `/Users/chriskarani/CodingProjects/rv`
Date: 2026-08-31
Source conversation: comparison of pinned 0.11.0 upstream vs rv; locked takes; spec + implementable program written; **no product code landed**.

**Executable prompt:** [`PROMPT.md`](PROMPT.md) in this same directory — paste that into a **new** session. Do not re-derive acceptance from this narrative. Do not re-argue which takes to ship.

**Law:** `spec/spec-architecture-product-takes.md` wins file list, APIs, and AC. `planning/2026-08-31-product-takes-implementable-program.md` wins wave/unit exclusive-writes. `docs/factory/PLAN.md` still wins product-law conflicts (no `RV_BYPASS`, no allow-because-XPC-missed, no command text in `os_log`). This program does **not** replace `docs/architecture/02.md` § Order. The human is **naming this program** for the new session; do not start OPE-156 / Host Ask unless they say so.

---

## Goal status

Make the live hook feel like a seatbelt at the block: teach a safer next step, cover disk-wipe commands on a fresh install, and unstick agents that are in a **real** Git rebase — without copying upstream bypass env, redeemable codes on the hook wire, a fake “my stack” switch, or 95 packs on by default.

| Slice | Status | Evidence |
|---|---|---|
| Wrapped-command unwrap (`bash -c` / `python -c` / …) | **Already shipped** (OPE-256) | `Sources/RVEngine/Unwrap.swift`; verify only |
| Safer next step on hook deny | **Open** | `hostDenyWhy` keeps first sentence only |
| `system.disk` default-on | **Open** | `dayOnePackIDs` is still two ids |
| Rebase auto-allow of checkout/restore discards | **Open** | Pack `explanation` claims it; no `.git` probe in Sources |
| Host Ask / ApprovalBridge | **Deferred** | `docs/architecture/02.md` step 6 (OPE-264) |
| Heredoc / AST / remaining catalog default-on / stack switch / `rv rebase-recover` cookie | **Deferred** | spec §1 Out of scope |

---

## What the next agent must read (in order)

1. `AGENTS.md`
2. `spec/spec-architecture-product-takes.md` (implementation contract)
3. `planning/2026-08-31-product-takes-implementable-program.md` (waves, exclusive-writes, algorithms)
4. This handoff + `PROMPT.md`
5. Then only the files for the wave you are on (do not pre-read the whole tree)

Skills (load before coding that wave):

| Wave | Skills |
|---|---|
| All | `.grok/skills/swift-feature-implementation` |
| W1 deny | `.grok/skills/swift-hook-xpc` |
| W2 packs | `.grok/skills/swift-hexagonal-spm`, `.grok/skills/swift-evaluate-parity` |
| W3 rebase | `.grok/skills/swift-evaluate-parity` |

Do **not** load `thermo-nuclear-code-quality-review`. Work only in this repo. Do not write foreign product names into product files.

---

## Branch / worktree (do not improvise)

The planning session was sitting on **`fix/install-real-download-progress`**. That branch is **unrelated**. Do **not** implement these takes there.

```text
feat/product-takes
```

Start from current **`main`** (or a worktree of `main`). Suggested split:

| Session | Scope | Why |
|---|---|---|
| 1 (this prompt, default) | All three waves | Spec is locked; one session can finish if gates stay green |
| Safer split | W1, then W2, then W3 | One PR per wave (hook voice vs pack defaults vs policy I/O) |

If the human says “W1 only”, stop after Wave W1 prove. Same for W2 / W3.

**Untracked planning files:** as of 2026-08-31 these may still be untracked in git:

- `spec/spec-architecture-product-takes.md`
- `planning/2026-08-31-product-takes-implementable-program.md`
- `planning/2026-08-31-product-takes/HANDOFF.md`
- `planning/2026-08-31-product-takes/PROMPT.md`

Keep them. Do not `git stash --include-untracked` them away. Bring them onto `feat/product-takes`. Do not commit unless the human asks.

---

## Tree truth (do not rediscover)

### Unwrap — already the floor

`unwrapCommand` peels `sudo` / `env` / `command` / `bash -c` / `sh -c` / `zsh -c` / `python -c` / `node -e` / `ruby -e` with depth/byte caps. Fail-closed `.unwrapLimited`. Wired through `analyzeSemantics` / `GatedEvaluate`. **Do not rewrite `Unwrap.swift` if `tools/gate.sh RVEngineTests RVServiceTests` is green.**

### Deny tip — one function throws the tip away

Pack `core.git` reset-hard `description` is already:

```text
git reset --hard destroys uncommitted changes. Use 'git stash' first.
```

`hostDenyWhy` in `Sources/RVHooks/HostDenyText.swift` cuts at the first `. ` and keeps only sentence 1. That is why the hook says:

```text
RV · Blocked. Destroys uncommitted changes.
```

Target (canonical, one line):

```text
RV · Blocked. Destroys uncommitted changes. Use 'git stash' first.
```

TTY `Suggestions.swift` already has stash / `--soft` essays. **Do not import `RVPresentation` into `RVHooks`.** Do not put `allow-once` / `Terminal` / redeem codes / boxes / ANSI / newlines on deny. `hookUnlockNext` stays on **Ask** lines only.

`Tests/RVHooksTests/HostDenyTextTests.swift` `assertHookDenyHasNoBypassOrEssay` currently **forbids** `git stash`. REQ-030: stop forbidding stash; still forbid `allow-once`, `Terminal`, command echo, boxes, ANSI, redeem.

Honor-path goldens that still pin the old string (update all):

- `Tests/RVHooksTests/HostDenyTextTests.swift` (`resetHardHostDeny`)
- `Tests/RVHooksTests/AdapterHookTests.swift`
- `Tests/RVServiceTests/HookEvaluateTests.swift`
- `Tests/RVCLITests/HookDispatchTests.swift`
- `Tests/RVCLITests/HookCommandTests.swift`
- `Tests/RVCLITests/LinuxCHookTests.swift`
- `Tests/RVTUITests/Fixtures/snapshots/phase-1b/host-deny-text-git-reset-hard.txt`
- `tools/c-hook-proof.sh` (`CANONICAL=`)
- `docs/factory/references/host-contracts-v1.md` (Chris 271 line)

Algorithm is in the implementable program § Implementor notes. Caps: omit sentence 2 if empty, bypass-ish tokens, newline, ANSI, box drawing, or why > 180 scalars after `RV · Blocked. `.

### Disk — imported, left off

Today:

```swift
public let dayOnePackIDs: [PackID] = [
    PackID(rawValue: "core.filesystem"),
    PackID(rawValue: "core.git"),
]
```

Also duplicated in:

- `PackSet.defaultIDs` = `[.coreFilesystem, .coreGit]` (`PackEnablement.swift`)
- `PackRegistry.loadDayOne` hardcoded `["core.filesystem", "core.git"]`
- `system.disk.json` `"enabled_by_default": false`
- `index.json` `"default_enabled"` two ids

Target: **only** add `system.disk`. Not `system.permissions`, not postgres, not docker.

Single source after the change: `dayOnePackIDs`. `PackSet.defaultIDs` **is** `dayOnePackIDs`. `loadDayOne` maps that array.

Cardinality landmines (will go red immediately):

- `enablement_defaultsAreCoreOnly` expects two ids and **excludes** `system.disk`
- `enablement_k8sCategoryAddsThreePlusCore` expects `raw.count == 5` → **6**
- `enablement_presetMembershipDropsWindowsOSPacks` comment `2 core + … = 33` → **34**
- `DoctorSnapshotBuilder`: `"core.git and core.filesystem loaded"`
- `CONTEXT.md` Day-one packs paragraph

Empty `[packs] enabled` in config still means **no extras**; defaults still union. Do **not** change “empty enabled means none” on `EvaluationRequest.enabledPacks` (cli-thin).

### Rebase — copy claims it; code never looks at `.git`

`RulePinning.blocksAllowOverride` pins `working-tree-discard`, so allow-once cannot save `git checkout --`. Rebase recovery must run **before** that pin, and must **not** treat `builtin.action:working-tree-discard` as eligible unless innermost `GitAction` is a rebase-eligible discard.

Eligible:

- `GitAction.discardWorktree`
- `GitAction.restore(..., worktree: true, ...)`
- if `gitAction` is nil: pack ids `checkout-discard`, `checkout-ref-discard`, `restore-worktree`, `restore-worktree-explicit`

**Never eligible:** `reset` (any mode), `clean`, `push`, `switchBranch`, stash, `git restore --staged` (worktree false). `git reset --hard` during rebase stays deny.

I/O: new `GitRebaseProbe` in **RVService** only. Reuse `FilesystemLiveProbe.discoverRepositoryRoot`. `.git` directory vs `gitdir:` file. True iff `rebase-merge` **or** `rebase-apply` is a **directory**. Nil cwd / unreadable gitdir → false (stay deny). Engine `evaluate` stays pure (no `FileManager`).

New `PolicyOverride.rebaseRecovery`. Does **not** consume `AllowOnceStore`. Default `rebaseInProgress: false` so existing PolicyGate tests keep compiling.

Seven temp-dir cases: spec REQ-069. No live HOME. No real `git rebase` required.

---

## What not to redo

- Re-compare upstream vs rv. Takes are locked.
- Reimplement unwrap / heredoc / AST.
- Host Ask, ApprovalBridge, new host adapters.
- `RV_BYPASS` or any hook-honored skip-evaluate env.
- Redeemable allow-once **code** on `hostDenyText` / deny fixtures.
- `rv rebase-recover` CLI / `.rv/rebase-recovery-permit`.
- A databases+docker+k8s “one switch” (category expand already exists).
- Enabling the rest of the catalog.
- Changing `Decision` (no Ask case).
- Importing `RVPresentation` from `RVHooks` or `RVPolicy`.
- `swift package clean` / wipe `.build` to prove compile.
- Live-HOME tests / `NSHomeDirectory()` as fixture root.
- Writing foreign product names into product files.
- Implementing on `fix/install-real-download-progress`.

---

## Effort (for session budgeting)

1. **W1 deny tip — small code, fixture blast.** ~10 goldens + tests that forbid `git stash`.
2. **W2 disk default — tiny switch, hunt literals.** Cardinality tests + doctor + CONTEXT + corpus rows.
3. **W3 rebase — largest / security-sensitive.** Probe + gate order + eligibility. Adversarial review after.

Unwrap: verify-only. If green, zero product edit.

---

## Verify (program complete)

```sh
tools/gate.sh RVEngineTests RVServiceTests
tools/gate.sh RVHooksTests
tools/c-hook-proof.sh
tools/gate.sh RVCLITests RVTUITests
tools/gate.sh RVDomainTests RVPacksTests RVCorpusTests RVServiceTests RVCLITests RVPresentationTests RVAnalyticsTests
tools/gate.sh RVPolicyTests
tools/gate.sh RVServiceTests
```

Polarity:

```sh
# fail if old exact deny line remains on honor paths (no stash clause)
rg -n "RV · Blocked. Destroys uncommitted changes[^\.]" Tests Sources tools docs/factory/references/host-contracts-v1.md

rg -n "RV_BYPASS" Sources   # no matches
```

---

## Commit / PR

Commit only if the human asks. Prefer **one PR per wave**. W3 is security-sensitive: do not allow `reset --hard` during rebase.

---

## End state for the next agent

When `PROMPT.md` checkboxes are green: unwrap still denies wrapped reset-hard; hook deny includes the stash tip on one line; fresh install compiles `system.disk`; postgres/docker still off; temp rebase dir allows `git checkout --` / worktree restore and still denies `git reset --hard`. Residuals (Ask, AST, rest of catalog, cookie CLI) stay registered, not implemented.
