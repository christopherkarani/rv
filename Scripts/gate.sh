#!/usr/bin/env bash
# Scripts/gate.sh — preflight + filtered swift test via Scripts/swift-6.4.
# Explicit filter wins. Else infer from git-changed Sources/Tests modules;
# a changed Sources module also selects every *Tests target that depends on
# it transitively (from the Package.swift graph). Package.swift → every
# *Tests. Never unfiltered full suite by default.
# Compatible with macOS /bin/bash 3.2 (no mapfile).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PREFLIGHT="$ROOT/Scripts/preflight.sh"
SWIFT_WRAP="$ROOT/Scripts/swift-6.4"
QUIET=0
EXPLICIT=0
FILTERS=""
RUN_C_UNITS=0

usage() {
  cat <<'EOF'
Usage: Scripts/gate.sh [--quiet] [--filter NAME] [FilterName ...]

  --quiet           Pass --quiet to preflight; less gate chatter
  --filter NAME     Explicit swift test --filter (repeatable / also positional)
  FilterName        Same as --filter (e.g. RVEngineTests)

With no filters: infer from git changes under Sources/ and Tests/.
A changed Sources module selects its own *Tests plus every *Tests target
that depends on it transitively (reverse dependents, read from
`swift package dump-package`). If Package.swift changed, run every *Tests. If nothing maps (or an empty --filter was given),
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

# Print every test target whose transitive target dependencies include one
# of the given Sources modules, one per line. Reads the evaluated manifest
# so platform-conditional targets match this host.
reverse_dependent_tests() {
  local manifest
  manifest="$("$SWIFT_WRAP" package dump-package 2>/dev/null)" || return 1
  printf '%s' "$manifest" | python3 -c '
import json, sys
changed = set(sys.argv[1:])
targets = json.load(sys.stdin)["targets"]
deps = {}
for target in targets:
    names = []
    for dep in target.get("dependencies", []):
        for kind in ("target", "byName"):
            if kind in dep:
                names.append(dep[kind][0])
    deps[target["name"]] = names
def closure(name, seen):
    for dep in deps.get(name, []):
        if dep not in seen:
            seen.add(dep)
            closure(dep, seen)
    return seen
for target in targets:
    if target.get("type") == "test" and closure(target["name"], set()) & changed:
        print(target["name"])
' "$@"
}

infer_filters() {
  local files f base m t package_touched=0 changed_modules=""
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
          rv-judge) add_filter "RVLayaTests" ;;
          rv-c)
            add_filter "CHookPipeTests"
            RUN_C_UNITS=1
            ;;
          *Tests) add_filter "$m" ;;
          *) add_filter "${m}Tests" ;;
        esac
        case "$f" in
          Sources/*) changed_modules="${changed_modules:+$changed_modules }$m" ;;
        esac
        ;;
    esac
  done <<<"$files"

  if [[ "$package_touched" -eq 1 ]]; then
    for d in Tests/*Tests; do
      [[ -d "$d" ]] || continue
      add_filter "$(basename "$d")"
    done
  elif [[ -n "$changed_modules" ]]; then
    local dependents
    # shellcheck disable=SC2086  # word-split the module list on purpose
    if dependents="$(reverse_dependent_tests $changed_modules)"; then
      while IFS= read -r t; do
        add_filter "$t"
      done <<<"$dependents"
    else
      printf "gate: could not read the package graph; dependents' tests not added\n" >&2
    fi
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
    printf "gate: empty filter list; pass e.g. Scripts/gate.sh RVDomainTests\n" >&2
  else
    printf "gate: no test filters inferred; pass e.g. Scripts/gate.sh RVDomainTests\n" >&2
  fi
  exit 2
fi

# One invocation: each `swift test --filter` re-plans and re-typechecks the
# graph, so a dozen filters cost a dozen plannings. The alternation matches
# the same union the loop ran.
fail=0
FILTER_REGEX="${FILTERS// /|}"
if [[ "$QUIET" -eq 0 ]]; then
  printf "gate: Scripts/swift-6.4 test --filter %s\n" "$FILTER_REGEX"
fi
if ! "$SWIFT_WRAP" test --filter "$FILTER_REGEX"; then
  fail=1
fi

if [[ "$RUN_C_UNITS" -eq 1 ]]; then
  if [[ "$QUIET" -eq 0 ]]; then
    printf "gate: Sources/rv-c/tests/run.sh\n"
  fi
  if ! "$ROOT/Sources/rv-c/tests/run.sh"; then
    fail=1
  fi
fi

exit "$fail"
