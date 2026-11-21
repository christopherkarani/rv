#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 [repo-path|owner/name] [--assert-empty]" >&2
  exit 2
}

repo=""
assert_empty=0
for arg in "$@"; do
  case "$arg" in
    --assert-empty) assert_empty=1 ;;
    -h|--help) usage ;;
    *)
      [[ -z "$repo" ]] || usage
      repo="$arg"
      ;;
  esac
done

if [[ -n "$repo" ]] && git -C "$repo" rev-parse --show-toplevel >/dev/null 2>&1; then
  remote="$(git -C "$repo" remote get-url upstream 2>/dev/null || git -C "$repo" remote get-url origin)"
  remote="${remote%.git}"
  remote="${remote#https://github.com/}"
  remote="${remote#http://github.com/}"
  remote="${remote#git@github.com:}"
  repo="$remote"
elif [[ -z "$repo" ]]; then
  repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
fi

prs="$(gh pr list --repo "$repo" --state open --limit 100 --json number,title,headRefName,baseRefName,headRefOid,baseRefOid,mergeable,mergeStateStatus,url)"

if [[ "$assert_empty" == 1 ]]; then
  count="$(jq 'length' <<<"$prs")"
  if [[ "$count" != 0 ]]; then
    jq -r '.[] | "OPEN #\(.number) \(.title) (\(.headRefName) -> \(.baseRefName))"' <<<"$prs" >&2
    exit 1
  fi
  echo "PASS: no open PRs in $repo"
  exit 0
fi

jq -r --arg repo "$repo" 'if length == 0 then "No open PRs in \($repo)" else (.[] | "#\(.number) \(.title) | \(.headRefName) [\(.headRefOid[0:8])] -> \(.baseRefName) [\(.baseRefOid[0:8])] | \(.mergeable)/\(.mergeStateStatus) | \(.url)") end' <<<"$prs"
