# Stale and Conflicting PRs

Load this reference when GitHub reports `CONFLICTING`, `DIRTY`, or a merge cannot be cleanly created.

1. Fetch the current base and record its OID. Inspect `git merge-base base head` and the PR’s actual `baseRefOid`; never assume the local `main` is current.
2. Create a disposable isolated worktree from the PR head. Preserve the original remote branch as the fast-forward ancestor when possible.
3. Merge the current base into the PR branch without committing. Resolve each conflict semantically: preserve current-base behavior plus the PR’s reviewed behavior. Keep public docs and tests aligned.
4. If the branch is a stale sibling whose intended change is already in base, do not reintroduce the old implementation. Add only a meaningful compatibility/regression test or a minimal reviewed fix if one is needed.
5. Run `git diff --stat base..HEAD`, `git diff --check`, focused tests, and the canonical gate. Inspect the final tree, not only conflict markers.
6. Push a normal fast-forward update. Never force-push. If a clean merge requires an explicit merge parent, use a deliberate merge commit whose tree has been inspected and verified.
7. Re-query GitHub after pushing. A local merge commit is not proof that GitHub accepted the PR.
