#!/usr/bin/env bash
# tools/gate.sh — preflight + filtered swift test via tools/swift-6.3.3.
# Explicit filter wins. Else infer from git-changed Sources/Tests modules;
# Package.swift or multi-module → union of affected *Tests. Never unfiltered
# full suite by default.
# Compatible with macOS /bin/bash 3.2 (no mapfile).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PREFLIGHT="$ROOT/tools/preflight.sh"
SWIFT_WRAP="$ROOT/tools/swift-6.3.3"
QUIET=0
EXPLICIT=0
FILTERS=""

usage() {
  cat <<'EOF'
Usage: tools/gate.sh [--quiet] [--filter NAME] [FilterName ...]

  --quiet           Pass --quiet to preflight; less gate chatter
  --filter NAME     Explicit swift test --filter (repeatable / also positional)
  FilterName        Same as --filter (e.g. RVEngineTests)

With no filters: infer from git changes under Sources/ and Tests/.
If Package.swift changed or multiple modules are touched, run the union of
affected *Tests targets. If nothing maps (or an empty --filter was given),
exit 2 — never exit 0 after preflight alone with zero tests.
EOF
}

add_filter() {
  local name="$1"
  [[ -z "$name" ]] && return
  case " $FILTERS " in
    *" $name "*) ;;
    *) FILTERS="${FILTERS:+$FILTERS }$name" ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    --filter)
      shift
      [[ $# -gt 0 ]] || { printf "gate: --filter needs a name\n" >&2; exit 2; }
      add_filter "$1"
      EXPLICIT=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      printf "gate: unknown option %s\n" "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      add_filter "$1"
      EXPLICIT=1
      shift
      ;;
  esac
done

while [[ $# -gt 0 ]]; do
  add_filter "$1"
  EXPLICIT=1
  shift
done

if [[ ! -x "$SWIFT_WRAP" ]]; then
  printf "gate: missing executable %s\n" "$SWIFT_WRAP" >&2
  exit 1
fi
if [[ ! -x "$PREFLIGHT" ]]; then
  printf "gate: missing executable %s\n" "$PREFLIGHT" >&2
  exit 1
fi

if [[ "$QUIET" -eq 1 ]]; then
  "$PREFLIGHT" --quiet
else
  "$PREFLIGHT"
fi

infer_filters() {
  local files f base m package_touched=0
  files="$(
    {
      git diff --name-only origin/main...HEAD 2>/dev/null || true
      git diff --name-only HEAD 2>/dev/null || true
      git diff --name-only --cached 2>/dev/null || true
      git ls-files --others --exclude-standard 2>/dev/null || true
    } | sort -u
  )"

  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    case "$f" in
      Package.swift)
        package_touched=1
        ;;
      Sources/*|Tests/*)
        case "$f" in
          Sources/*/*|Tests/*/*) ;;
          *) continue ;;
        esac
        base="${f#Sources/}"
        base="${base#Tests/}"
        m="${base%%/*}"
        case "$m" in
          rv|rvd) ;;
          *Tests) add_filter "$m" ;;
          *) add_filter "${m}Tests" ;;
        esac
        ;;
    esac
  done <<<"$files"

  if [[ "$package_touched" -eq 1 ]]; then
    for d in Tests/*Tests; do
      [[ -d "$d" ]] || continue
      add_filter "$(basename "$d")"
    done
  fi

  # Session forensics suite once the module exists (AC-015).
  if [[ -d Tests/RVScanTests ]]; then
    add_filter "RVScanTests"
  fi
}

if [[ "$EXPLICIT" -eq 0 ]]; then
  infer_filters
  if [[ "$QUIET" -eq 0 && -n "$FILTERS" ]]; then
    printf "gate: inferred filters: %s\n" "$FILTERS"
  fi
fi

# Explicit empty --filter / blank names must not green-exit after preflight alone.
if [[ -z "$FILTERS" ]]; then
  if [[ "$EXPLICIT" -eq 1 ]]; then
    printf "gate: empty filter list; pass e.g. tools/gate.sh RVDomainTests\n" >&2
  else
    printf "gate: no test filters inferred; pass e.g. tools/gate.sh RVDomainTests\n" >&2
  fi
  exit 2
fi

fail=0
for filt in $FILTERS; do
  if [[ "$QUIET" -eq 0 ]]; then
    printf "gate: tools/swift-6.3.3 test --filter %s\n" "$filt"
  fi
  if ! "$SWIFT_WRAP" test --filter "$filt"; then
    fail=1
  fi
done

exit "$fail"
