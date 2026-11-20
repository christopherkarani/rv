# Issue tracker: GitHub

Issues and specs for this repo live as GitHub issues in `christopherkarani/rv`. Use the `gh` CLI for all operations.

Use **`gh api` REST calls**, as written below, not `gh issue …` / `gh pr …`. Those subcommands go through GitHub's GraphQL API, which Claude Code cloud sessions block (HTTP 403). The REST calls work both there and locally. In a cloud session the GitHub MCP tools (`issue_read`, `issue_write`, `sub_issue_write`, `add_issue_comment`) are an equivalent alternative.

`R=repos/christopherkarani/rv` in the commands below.

## Conventions

- **Create an issue**: `gh api $R/issues -f title='...' -f body="$(cat <<'EOF' ... EOF)" -f 'labels[]=needs-triage' --jq .number`. Repeat `-f 'labels[]=…'` for more labels.
- **Read an issue**: `gh api $R/issues/<n> --jq '{number, title, state, body, labels: [.labels[].name]}'`, then `gh api $R/issues/<n>/comments --jq '.[].body'`.
- **List issues**: `gh api --paginate "$R/issues?state=open&labels=<label>&per_page=100" --jq '.[] | select(.pull_request | not) | {number, title, labels: [.labels[].name]}'`. The issues endpoint also returns PRs; the `select` drops them.
- **Database id** (needed for sub-issues and blocking): `gh api $R/issues/<n> --jq .id`. This is _not_ the `#number` or `node_id`.
- **Make an issue a sub-issue of a parent**: `gh api --method POST $R/issues/<parent>/sub_issues -F sub_issue_id=<child-db-id>`. Without sub-issues, put `Part of #<parent>` at the top of the child body.
- **Blocking**: GitHub's **native issue dependencies**, the canonical, UI-visible representation. Add an edge with `gh api --method POST $R/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`. Where dependencies aren't available, fall back to a `Blocked by: #<n>, #<n>` line at the top of the child body. A ticket is unblocked when every blocker is closed.
- **Count open blockers**: `gh api $R/issues/<n> --jq '.issue_dependencies_summary.blocked_by // 0'` (open blockers only; 0 means startable). `gh api $R/issues/<n>/dependencies/blocked_by` also lists closed blockers, so filter it: `--jq '[.[] | select(.state == "open")] | length'`.
- **Comment on an issue**: `gh api $R/issues/<n>/comments -f body='...'`
- **Apply / remove labels**: `gh api $R/issues/<n>/labels -f 'labels[]=<label>'` / `gh api --method DELETE $R/issues/<n>/labels/<label>`
- **Close**: post the explanation with the comment call above, then `gh api --method PATCH $R/issues/<n> -f state=closed -f state_reason=completed` (`not_planned` for wontfix).

File issues only into `christopherkarani/rv`. Never file into `mattpocock/skills` (the repo these skills come from).

## Pull requests as a triage surface

**PRs as a request surface: no.** _(Set to `yes` if this repo treats external PRs as feature requests; `/triage` reads this flag.)_

When set to `yes`, PRs run through the same labels and states as issues. PRs share the issues endpoints for comments, labels and closing (`$R/issues/<n>/…` with the PR number), plus:

- **Read a PR**: `gh api $R/pulls/<n> --jq '{number, title, body, user: .user.login}'`, comments via `gh api $R/issues/<n>/comments`, and the diff via `gh api $R/pulls/<n> -H 'Accept: application/vnd.github.diff'`.
- **List external PRs for triage**: `gh api --paginate "$R/pulls?state=open" --jq '.[] | select(.author_association | IN("OWNER","MEMBER","COLLABORATOR") | not) | {number, title, author: .user.login, author_association, labels: [.labels[].name]}'`.

GitHub shares one number space across issues and PRs, so a bare `#42` may be either: `gh api $R/issues/42 --jq '.pull_request != null'` tells you which.

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

Read it as in **Read an issue** above.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single issue with **child** issues as tickets.

- **Map**: a single issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body. Create it as above with `-f 'labels[]=wayfinder:map'`.
- **Child ticket**: an issue linked to the map as a GitHub sub-issue (see **Make an issue a sub-issue of a parent**). Where sub-issues aren't enabled, add the child to a task list in the map body and put `Part of #<map>` at the top of the child body. Labels: `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`). Once claimed, the ticket is assigned to the driving dev.
- **Blocking**: see **Blocking** under Conventions.
- **Frontier query**: list the map's open children (`gh api $R/issues/<map>/sub_issues --jq '.[] | select(.state == "open") | {number, title, assignees: [.assignees[].login]}'`, or the map's task list), drop any with an open blocker (see **Count open blockers**, or an open issue in the `Blocked by` line) or an assignee; first in map order wins.
- **Claim**: `gh api $R/issues/<n>/assignees -f "assignees[]=$(gh api user --jq .login)"`, the session's first write.
- **Resolve**: comment the answer, close the issue (see **Close**), then append a context pointer (gist + link) to the map's Decisions-so-far.
