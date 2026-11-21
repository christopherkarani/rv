---
name: swift-pr-orchestration
description: "Orchestrate adversarial review, implementation, verification, and merge of Swift pull requests. Use when users ask to review, audit, inspect, fix, repair, refactor, validate, reconcile, push, or merge Swift PRs, GitHub pull requests, SwiftPM packages, Xcode projects, concurrency changes, API migrations, persistence changes, or related PR stacks; trigger on phrases like 'review all open PRs', 'launch agents per PR', 'fix the findings', 'make a merge plan', 'merge every PR', or 'automate this Swift PR workflow'."
---

# Swift Pr Orchestration

IRON LAW: NEVER PUSH OR MERGE A SWIFT PR UNTIL ITS ACTUAL PR DIFF HAS BEEN ADVERSARIALLY REVIEWED, ALL BLOCKING FINDINGS HAVE A VERIFIED FIX, AND THE TARGET BRANCH HAS A CLEAN MERGE PATH.

This skill orchestrates agents and GitHub state; it does not replace engineering judgment. Preserve user edits and isolate branch work. Treat compatibility, persistence, platform availability, and Swift concurrency as release-blocking concerns.

## Options

| Option | Meaning | Default |
|---|---|---|
| `<repo>` | Repository path or `owner/name`; omit to use the current repo | current repo |
| `--pr N` | Operate on selected PR number(s); repeat for a subset | all open PRs |
| `--plan-only` | Inventory, review, and plan without changing files or GitHub state | off |
| `--apply` | Permit fix-agent commits and branch pushes after confirmation | off |
| `--merge` | Permit PR merges after verification and confirmation | off |
| `--quick` | Use discovered defaults and skip the planning confirmation only when explicitly requested | off |

`--merge` implies `--apply`. Never infer either flag from a request to “look at” or “review” PRs. A direct user request to merge all PRs is authorization for the scoped pushes and merges, but still requires the checks below.

## Workflow

Copy this checklist and check off items as you complete them:

```
Swift PR Orchestration Progress:

- [ ] Step 0: Load repository rules and establish a clean baseline ⛔ BLOCKING
- [ ] Step 1: Inventory every target PR and its exact base/head ⚠️ REQUIRED
- [ ] Step 2: Have a planning agent group related PRs and assign skills ⚠️ REQUIRED
- [ ] Step 3: Launch one adversarial review agent per PR ⚠️ REQUIRED
- [ ] Step 4: Present the merge plan and obtain change authority ⚠️ REQUIRED
- [ ] Step 5: Launch one implementation agent per PR with explicit file ownership
- [ ] Step 6: Re-review fixes, run focused checks, and reconcile stale branches
- [ ] Step 7: Push and merge in dependency order (conditional: `--merge`)
- [ ] Step 8: Verify merged main, zero open PRs, and report residual failures
```

## Step 0: Establish the repository boundary ⛔ BLOCKING

1. Read the nearest `AGENTS.md`, `CLAUDE.md`, package manifest, CI scripts, and project-local Swift instructions. Load only relevant skills; for Swift PRs prefer `swift-adversarial-pr-review`, `swift-pr-review`, `swift-concurrency`, `swift-api-design-guidelines`, `swift-testing-pro`, and the project’s domain skills. On a Swift 6.4 toolchain, also load `swift-64-whats-new` when the diff uses 6.4-only APIs.
2. Record `git status --short`, current branch/HEAD, remotes, Swift/Xcode toolchain, and the project’s real test/build commands. Do not reset, stash, clean, checkout over, or stage user changes.
3. If the checkout is dirty, either work in fresh isolated worktrees or stop and report the overlap. Never use the shared dirty checkout as an implementation worktree.

## Step 1: Inventory exact PR scope ⚠️ REQUIRED

Run `scripts/audit_open_prs.sh <repo>` or equivalent `gh pr list`/`gh pr view` calls. Capture for every PR: number, title, base ref/OID, head ref/OID, branch, mergeability, changed files, and whether it is stacked or stale.

Ask: “What is the actual diff from this PR’s base, and what later PRs or current-main commits already contain the same change?” Do not review `head..current-main` as though it were the PR diff.

Load `references/merge-conflicts.md` when a PR base is stale, conflicting, or a sibling branch already contains part of its intended change.

## Step 2: Planning agent and skill distribution ⚠️ REQUIRED

Launch one planning agent with the complete inventory. Require it to return dependency/stack groups, a safe merge order, duplicate or already-landed changes, compatibility risks, exact review/implementation skills, focused/full verification commands, and hold conditions.

Ask: “Which PRs touch the same public API, persistence format, package graph, or concurrency seam, and which order minimizes semantic drift?” Save the plan locally only if the project permits internal artifacts; never stage internal plan files in a public repository.

Load `references/skill-distribution.md` when assigning specialist skills.

## Step 3: Adversarial review agent per PR ⚠️ REQUIRED

Launch exactly one read-only review agent for each target PR. Give each agent the PR number, exact base/head, repository path, review scope, and planner-selected skills. Require evidence-backed findings with severity, file/line, failure scenario, and a minimal fix recommendation.

The reviewer must ask:

- What happens on cancellation, task cancellation during callbacks/sleeps, actor isolation, detached tasks, and Sendable crossings?
- What happens for empty, nil, negative, overflowing, repeated, resumed, or concurrently accessed values?
- Does the public API remain source-compatible at the current package version?
- Are Codable/persisted identifiers and historical representations still readable?
- Are iOS/macOS/Linux/compiler/SwiftPM trait paths compiled and tested correctly?
- Does the test actually exercise the changed behavior rather than only compile?

Load `references/swift-pr-review.md` for the detailed checklist. Treat P0/P1 findings as merge blockers; record P2/P3 follow-ups separately.

## Step 4: Confirmation gate ⚠️ REQUIRED

Present the planner’s merge order, review findings, proposed files per fix agent, verification lanes, and any destructive/network operations. Ask whether to plan only, apply fixes without pushing, apply/push/merge all, or select specific PRs/severities. Proceed without a second question only when the user’s message clearly authorizes the selected scope. `--plan-only` always overrides mutation.

## Step 5: Implementation agent per PR

Launch one implementation agent per PR in a dedicated worktree or branch. Give it only that PR’s findings, exact branch/base/head, explicit file ownership, assigned skills, and acceptance criteria. Tell it that other agents exist and it must preserve unrelated work.

Require the agent to reproduce or characterize each finding, add a focused regression test, preserve compatibility unless a breaking boundary is approved, run `git diff --check` and the narrowest relevant check, and report changed files, results, and unresolved environment failures. Do not let agents force-push, merge, delete branches, or modify the shared checkout.

## Step 6: Re-review and verify

Inspect every final diff against its PR base. Re-run review for high-risk compatibility, persistence, concurrency, package-graph, and platform fixes. Confirm restoration shims do not alter canonical behavior. Run SwiftPM checks serially with isolated scratch/module caches and distinguish source failures from sandbox, dependency, toolchain, network, hardware, and baseline failures.

Before pushing, require a clean implementation worktree, no internal artifacts staged, no conflict markers, passing `git diff --check`, passing focused regression checks or a documented environment blocker, a clean merge path, and no unresolved P0/P1 findings.

## Step 7: Push and merge (conditional: `--merge`)

Push only the named branch ref without force. For stale branches, load `references/merge-conflicts.md`, integrate the current base in isolation, inspect every conflict, and preserve both current-main behavior and the reviewed PR behavior. Merge in planner order; re-query GitHub after each merge and refresh the base before advancing.

## Step 8: Final verification and output

Run `scripts/audit_open_prs.sh <repo> --assert-empty`, verify the final remote main SHA, and run the full supported Swift gate. Use this result format:

| PR | Review | Fix | Verification | Merge commit |
|---|---|---|---|---|
| #N | P0/P1/P2/P3 summary | commit/none | commands and result | SHA or blocked |

Finish with the final main SHA, open PR count, tests/builds, unresolved blockers, and confirmation that the shared checkout was preserved.

## Anti-Patterns

- Do not review every commit reachable from a branch as though it were that PR’s authored diff.
- Do not remove deprecated public APIs, Codable keys, persisted signatures, or platform shims merely because they look unused.
- Do not run parallel SwiftPM builds that share `.build`, module caches, or scratch paths.
- Do not declare a focused test green as proof that the repository-wide gate is green.
- Do not use `git reset --hard`, broad restore/checkout, `git clean`, force-push, or automatic branch deletion.
- Do not stage `tasks/`, `.claude/`, assistant reports, prompts, secrets, or generated internal artifacts in a public repo.
- Do not merge a stale branch because GitHub temporarily reports `UNKNOWN`, `UNSTABLE`, or `MERGEABLE` without verifying the current base/head.
- Do not create a new follow-up PR to hide a defect discovered in the current lane without telling the user and verifying that it is also merged.

## Pre-Delivery Checklist

- [ ] The target PR inventory contains every open PR in scope with exact base/head OIDs.
- [ ] A planning agent returned merge order, related groups, and skill assignments.
- [ ] Every target PR has one adversarial review result and one implementation-agent result.
- [ ] Each changed PR was checked against its actual base diff.
- [ ] No P0/P1 finding remains unresolved, and every compatibility/persistence concern is explicit.
- [ ] Focused regression checks and the project’s real gate were run with isolated SwiftPM caches when needed.
- [ ] Every pushed branch advanced without force-push and every merge was confirmed by GitHub state.
- [ ] `scripts/audit_open_prs.sh --assert-empty` passes.
- [ ] The final remote main SHA and test counts are recorded.
- [ ] The user’s shared checkout remains untouched or its pre-existing changes are explicitly listed.
