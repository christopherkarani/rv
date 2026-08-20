#!/usr/bin/env bash
# tools/worktree-cleanup.sh — list (default) or prune safe stale worktrees.
# Default is dry-run. --apply removes only:
#   - detached worktrees under /var/folders (agent temps)
#   - feat/* worktrees whose branch is fully merged into origin/main
#     and have no unique unpushed commits vs origin/main
# Never removes the primary checkout.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APPLY=0
usage() {
  cat <<'EOF'
Usage: tools/worktree-cleanup.sh [--apply]

  (default)  Dry-run: print safe prune candidates
  --apply    Remove only narrow safe candidates (see script header)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    *)
      printf "worktree-cleanup: unknown option %s\n" "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

MAIN_ROOT="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
# Prefer the worktree that has branch main checked out, else this ROOT
PRIMARY="$(git worktree list --porcelain | awk '
  /^worktree / { wt=$2 }
  /^branch refs\/heads\/main$/ { print wt; exit }
')"
if [[ -z "${PRIMARY:-}" ]]; then
  PRIMARY="$ROOT"
fi
PRIMARY="$(cd "$PRIMARY" && pwd)"

if ! git rev-parse --verify origin/main >/dev/null 2>&1; then
  printf "worktree-cleanup: origin/main missing; fetch first\n" >&2
  exit 1
fi

# Parse porcelain into records: path|head|branch|detached
candidates=()
reasons=()

wt=""
head=""
branch=""
detached=0
flush() {
  [[ -z "$wt" ]] && return
  local abs reason ok=0
  abs="$(cd "$wt" 2>/dev/null && pwd || echo "$wt")"
  if [[ "$abs" == "$PRIMARY" ]]; then
    wt=""; head=""; branch=""; detached=0
    return
  fi
  reason=""
  if [[ "$detached" -eq 1 ]]; then
    case "$abs" in
      /var/folders/*)
        ok=1
        reason="detached under /var/folders"
        ;;
    esac
  elif [[ -n "$branch" ]]; then
    local short="${branch#refs/heads/}"
    case "$short" in
      feat/*)
        if git merge-base --is-ancestor "$head" origin/main 2>/dev/null; then
          # No commits on this branch not in origin/main
          if [[ -z "$(git log origin/main.."$head" --oneline 2>/dev/null)" ]]; then
            ok=1
            reason="merged feat/* ($short)"
          fi
        fi
        ;;
    esac
  fi
  if [[ "$ok" -eq 1 ]]; then
    candidates+=("$abs")
    reasons+=("$reason")
  fi
  wt=""; head=""; branch=""; detached=0
}

while IFS= read -r line; do
  case "$line" in
    worktree\ *)
      flush
      wt="${line#worktree }"
      ;;
    HEAD\ *)
      head="${line#HEAD }"
      ;;
    branch\ *)
      branch="${line#branch }"
      ;;
    detached)
      detached=1
      ;;
    "")
      flush
      ;;
  esac
done < <(git worktree list --porcelain)
flush

if [[ ${#candidates[@]} -eq 0 ]]; then
  printf "worktree-cleanup: no safe candidates\n"
  exit 0
fi

i=0
for c in "${candidates[@]}"; do
  printf "worktree-cleanup: %s — %s\n" "$c" "${reasons[$i]}"
  i=$((i + 1))
done

if [[ "$APPLY" -eq 0 ]]; then
  printf "worktree-cleanup: dry-run only (%d candidate(s)); re-run with --apply to prune\n" "${#candidates[@]}"
  exit 0
fi

i=0
for c in "${candidates[@]}"; do
  printf "worktree-cleanup: removing %s (%s)\n" "$c" "${reasons[$i]}"
  git worktree remove --force "$c"
  i=$((i + 1))
done

git worktree prune
printf "worktree-cleanup: done\n"
