#!/usr/bin/env bash
# rv preflight — encodes the grok skill checklists as exit-code assertions.
#
# Sources:
#   .grok/skills/swift-hexagonal-spm/SKILL.md       (module law, graph, value types)
#   .grok/skills/swift-evaluate-parity/SKILL.md      (evaluate contract, corpus integrity)
#   .grok/skills/swift-hook-xpc/SKILL.md             (hook wire, deny path, no bypass)
#   .grok/skills/swift-thermo-nuclear-review/SKILL.md (maintainability bar)
#
# Usage:
#   tools/preflight.sh              # run all checks, exit 1 on any failure
#   tools/preflight.sh --quiet      # only print failures
#   tools/preflight.sh --check NAME # run one check (see --list)
#   tools/preflight.sh --list       # list available checks
#
# Does NOT run swift test. Pair with: swift test --filter <Target>Tests
# Does NOT require 6.3.3 on PATH — that's the caller's job (see docs/dev/SWIFT.md).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCES="$ROOT/Sources"
TESTS="$ROOT/Tests"
CORPUS="$TESTS/RVEngineTests/Fixtures/corpus"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

QUIET=0
ONLY=""
FAILURES=0
WARNINGS=0

print_list() {
  cat <<'EOF'
Available checks:
  value-types           No class declarations outside RVService/XPC NSObject edge
  no-isdenied           No boolean isDenied anywhere in Sources
  no-force-unwrap       No try! or force-unwrap on production paths
  no-exported-import    No new @_exported import (existing T1 debt is known)
  evaluate-pure         evaluate has no Date(), FileManager, or ProcessInfo
  no-bypass             No RV_BYPASS or env that skips evaluate
  no-ns-home             No NSHomeDirectory() in Sources or Tests
  no-os-log-cmdtext     No command text written to os_log (structural check)
  name-hygiene          No dcg/ryk tokens outside docs/factory/
  no-xctest             Tests use Swift Testing, not XCTest
  no-main-in-library     No main.swift or @main in library targets
  graph-no-engine-packs  RVEngine does not import RVPacks
  corpus-quarantine     reset-hard and fork-bomb are not in quarantine.json
  corpus-landmines      near-miss.json retains required landmine commands
  corpus-structure      All corpus files have valid schema (cases array)
  test-target-isolation Only RVCorpusTests may list 3+ module deps
EOF
}

# ─── Helpers ─────────────────────────────────────────────────────────────────

# Count matches; return 0 (pass) if count is 0, 1 (fail) otherwise.
# Prints the count and any matching lines (unless --quiet).
check_empty() {
  local label="$1"
  local pattern="$2"
  shift 2
  local matches
  matches=$(grep -rn -- "$pattern" "$@" 2>/dev/null || true)
  local count
  count=$(echo "$matches" | grep -c . || true)
  if [ "$count" -eq 0 ]; then
    if [ "$QUIET" -eq 0 ]; then printf "  ${GREEN}✓${NC} %s\n" "$label"; fi
    return 0
  else
    printf "  ${RED}✗ %s${NC} (%d match%s)\n" "$label" "$count" "$([ "$count" -ne 1 ] && echo es || true)"
    if [ "$QUIET" -eq 0 ]; then
      echo "$matches" | head -15 | sed 's/^/    /'
      [ "$count" -gt 15 ] && echo "    … ($(( count - 15 )) more)"
    fi
    return 1
  fi
}

# Same as check_empty but warns instead of failing.
warn_empty() {
  local label="$1"
  local pattern="$2"
  shift 2
  local matches
  matches=$(grep -rn -- "$pattern" "$@" 2>/dev/null || true)
  local count
  count=$(echo "$matches" | grep -c . || true)
  if [ "$count" -eq 0 ]; then
    if [ "$QUIET" -eq 0 ]; then printf "  ${GREEN}✓${NC} %s\n" "$label"; fi
    return 0
  else
    printf "  ${YELLOW}⚠ %s${NC} (%d match%s, known debt)\n" "$label" "$count" "$([ "$count" -ne 1 ] && echo es || true)"
    if [ "$QUIET" -eq 0 ]; then
      echo "$matches" | head -5 | sed 's/^/    /'
    fi
    WARNINGS=$((WARNINGS + 1))
    return 0
  fi
}

# ─── Checks ──────────────────────────────────────────────────────────────────

check_value_types() {
  # class declarations anywhere except RVService (the XPC/NSObject edge)
  local matches
  matches=$(grep -rn '^\s*\(public \|internal \|private \|fileprivate \|open \)*class ' "$SOURCES" --include='*.swift' \
    | grep -v 'Sources/RVService/' || true)
  local count
  count=$(echo "$matches" | grep -c . || true)
  if [ "$count" -eq 0 ]; then
    if [ "$QUIET" -eq 0 ]; then printf "  ${GREEN}✓${NC} %s\n" "No class declarations outside RVService"; fi
    return 0
  else
    printf "  ${RED}✗ class declarations outside RVService${NC} (%d)\n" "$count"
    echo "$matches" | head -15 | sed 's/^/    /'
    return 1
  fi
}

check_no_isdenied() {
  check_empty "No boolean isDenied" 'isDenied' "$SOURCES" --include='*.swift'
}

check_no_force_unwrap() {
  # try! in production Sources
  local fail=0
  check_empty "No try! in Sources" 'try!' "$SOURCES" --include='*.swift' || fail=1
  return $fail
}

check_no_exported_import() {
  # Existing @_exported in RVEngine/RVPacks is documented T1 debt (SKILL.md).
  # Flag as warning, not failure. New ones outside those two files WOULD fail.
  local matches
  matches=$(grep -rn '@_exported' "$SOURCES" --include='*.swift' || true)
  local count
  count=$(echo "$matches" | grep -c . || true)
  if [ "$count" -eq 0 ]; then
    if [ "$QUIET" -eq 0 ]; then printf "  ${GREEN}✓${NC} %s\n" "No @_exported import"; fi
    return 0
  fi
  # Check if all matches are in RVEngine.swift or RVPacks.swift (known T1 debt)
  local non_debt
  non_debt=$(echo "$matches" | grep -v 'RVEngine.swift:' | grep -v 'RVPacks.swift:' || true)
  local non_debt_count
  non_debt_count=$(echo "$non_debt" | grep -c . || true)
  if [ "$non_debt_count" -gt 0 ]; then
    printf "  ${RED}✗ New @_exported import outside known T1 debt${NC} (%d)\n" "$non_debt_count"
    echo "$non_debt" | head -10 | sed 's/^/    /'
    return 1
  else
    printf "  ${YELLOW}⚠ @_exported import${NC} (%d, known T1 debt in RVEngine/RVPacks)\n" "$count"
    WARNINGS=$((WARNINGS + 1))
    return 0
  fi
}

check_evaluate_pure() {
  local fail=0
  local engine="$SOURCES/RVEngine"
  check_empty "evaluate pure: no Date()" 'Date()' "$engine" --include='*.swift' || fail=1
  check_empty "evaluate pure: no FileManager" 'FileManager' "$engine" --include='*.swift' || fail=1
  check_empty "evaluate pure: no ProcessInfo" 'ProcessInfo' "$engine" --include='*.swift' || fail=1
  return $fail
}

check_no_bypass() {
  check_empty "No RV_BYPASS or skip-evaluate env" 'RV_BYPASS' "$SOURCES" --include='*.swift'
}

check_no_ns_home() {
  local fail=0
  check_empty "No NSHomeDirectory() in Sources" 'NSHomeDirectory' "$SOURCES" --include='*.swift' || fail=1
  check_empty "No NSHomeDirectory() in Tests" 'NSHomeDirectory' "$TESTS" --include='*.swift' || fail=1
  return $fail
}

check_no_os_log_cmdtext() {
  # Structural: if os_log/OSLog/Logger is used, flag for manual review.
  # PLAN says "no command text in os_log". We can't detect command text in logs
  # structurally, but we can flag os_log usage for review.
  local matches
  matches=$(grep -rn 'os_log\|OSLog\|Logger(' "$SOURCES" --include='*.swift' || true)
  local count
  count=$(echo "$matches" | grep -c . || true)
  if [ "$count" -eq 0 ]; then
    if [ "$QUIET" -eq 0 ]; then printf "  ${GREEN}✓${NC} %s\n" "No os_log usage (no command-text risk)"; fi
    return 0
  else
    printf "  ${YELLOW}⚠ os_log/Logger usage${NC} (%d site%s — verify no command text)\n" "$count" "$([ "$count" -ne 1 ] && echo s || true)"
    if [ "$QUIET" -eq 0 ]; then
      echo "$matches" | head -10 | sed 's/^/    /'
    fi
    WARNINGS=$((WARNINGS + 1))
    return 0
  fi
}

check_name_hygiene() {
  # PLAN #20: no dcg or ryk tokens outside docs/factory/ in product files.
  #
  # Two tiers:
  #   FAIL  — token in product code (Sources, Tests, Package.swift, root configs)
  #   WARN  — token in agent-config dotfiles (.ryk, .claude-plugin, .agents)
  #           These are pre-existing multi-tool configs, not product code, but
  #           worth surfacing so an agent doesn't "clean up" what looks stray.
  #
  # Excludes: .build, .git, .worktrees (worktree copies are not product files),
  # docs/factory (allowed), tools/preflight.sh (self — must contain the tokens),
  # .gitignore (path reference, not a product name).

  # Product files: Sources, Tests, and root-level non-dotfile configs.
  local product_matches
  product_matches=$(rg -i --no-ignore-vcs \
    --glob '!docs/factory/**' \
    --glob '!.build/**' \
    --glob '!.git/**' \
    --glob '!.worktrees/**' \
    --glob '!tools/preflight.sh' \
    --glob '!.gitignore' \
    --glob '!**/.ryk/**' \
    --glob '!**/.claude-plugin/**' \
    --glob '!**/.agents/**' \
    'dcg|ryk' \
    "$ROOT/Sources" "$ROOT/Tests" "$ROOT/Package.swift" "$ROOT/README.md" "$ROOT/AGENTS.md" "$ROOT/CONTEXT.md" \
    --files-with-matches 2>/dev/null || true)
  local pcount
  pcount=$(echo "$product_matches" | grep -c . || true)

  # Agent config dotfiles: warn only.
  local config_matches
  config_matches=$(rg -i --no-ignore-vcs \
    --glob '!.build/**' \
    'dcg|ryk' \
    "$ROOT/.claude-plugin" "$ROOT/.agents" "$ROOT/.ryk" \
    --files-with-matches 2>/dev/null || true)
  local ccount
  ccount=$(echo "$config_matches" | grep -c . || true)

  if [ "$pcount" -gt 0 ]; then
    printf "  ${RED}✗ Name hygiene: dcg/ryk in product files${NC} (%d)\n" "$pcount"
    echo "$product_matches" | head -15 | sed 's/^/    /'
    return 1
  fi
  if [ "$ccount" -gt 0 ]; then
    printf "  ${YELLOW}⚠ dcg/ryk in agent-config dotfiles${NC} (%d, pre-existing — not product code)\n" "$ccount"
    WARNINGS=$((WARNINGS + 1))
  fi
  if [ "$QUIET" -eq 0 ]; then printf "  ${GREEN}✓${NC} %s\n" "Name hygiene: no dcg/ryk in product files"; fi
  return 0
}

check_no_xctest() {
  check_empty "Tests use Swift Testing, not XCTest" 'import XCTest' "$TESTS" --include='*.swift'
}

check_no_main_in_library() {
  # main.swift or @main only in executable targets (Sources/rv, Sources/rvd)
  local fail=0
  local matches
  matches=$(find "$SOURCES" -name 'main.swift' \
    | grep -v 'Sources/rv/' | grep -v 'Sources/rvd/' || true)
  local count
  count=$(echo "$matches" | grep -c . || true)
  if [ "$count" -gt 0 ]; then
    printf "  ${RED}✗ main.swift in library target${NC} (%d)\n" "$count"
    echo "$matches" | head -10 | sed 's/^/    /'
    fail=1
  else
    if [ "$QUIET" -eq 0 ]; then printf "  ${GREEN}✓${NC} %s\n" "No main.swift in library targets"; fi
  fi
  # @main in library target source files
  local amatches
  amatches=$(grep -rn '@main' "$SOURCES" --include='*.swift' \
    | grep -v 'Sources/rv/' | grep -v 'Sources/rvd/' || true)
  local acount
  acount=$(echo "$amatches" | grep -c . || true)
  if [ "$acount" -gt 0 ]; then
    printf "  ${RED}✗ @main in library target${NC} (%d)\n" "$acount"
    echo "$amatches" | head -10 | sed 's/^/    /'
    fail=1
  fi
  return $fail
}

check_graph_no_engine_packs() {
  check_empty "RVEngine does not import RVPacks" 'import RVPacks' "$SOURCES/RVEngine" --include='*.swift'
}

check_corpus_quarantine() {
  # Never quarantine reset-hard or fork-bomb
  local fail=0
  local qfile="$CORPUS/quarantine.json"
  if [ ! -f "$qfile" ]; then
    printf "  ${RED}✗ quarantine.json missing${NC}\n"
    return 1
  fi
  local found
  found=$(python3 -c "
import json, sys
d = json.load(open('$qfile'))
for c in d.get('cases', []):
    blob = json.dumps(c)
    if 'reset-hard' in blob or 'fork-bomb' in blob:
        print(c.get('id', '?'))
" 2>/dev/null || true)
  local count
  count=$(echo "$found" | grep -c . || true)
  if [ "$count" -gt 0 ]; then
    printf "  ${RED}✗ reset-hard/fork-bomb in quarantine.json${NC} (%d)\n" "$count"
    echo "$found" | sed 's/^/    /'
    return 1
  else
    if [ "$QUIET" -eq 0 ]; then printf "  ${GREEN}✓${NC} %s\n" "reset-hard/fork-bomb not in quarantine"; fi
    return 0
  fi
}

check_corpus_landmines() {
  # near-miss.json must retain required allow landmine commands.
  # These are the rows agents keep deleting to go green (SKILL landmines.md).
  local nfile="$CORPUS/near-miss.json"
  if [ ! -f "$nfile" ]; then
    printf "  ${RED}✗ near-miss.json missing${NC}\n"
    return 1
  fi
  local missing
  missing=$(python3 -c "
import json
d = json.load(open('$nfile'))
cmds = [c.get('command','').lower() for c in d.get('cases', [])]
required = [
    'force-with-lease',
    'checkout -b',
    'restore',
    'rg',
]
for r in required:
    if not any(r in c for c in cmds):
        print(r)
" 2>/dev/null || true)
  local count
  count=$(echo "$missing" | grep -c . || true)
  if [ "$count" -gt 0 ]; then
    printf "  ${RED}✗ near-miss.json missing required landmine commands${NC} (%d)\n" "$count"
    echo "$missing" | sed 's/^/    /'
    return 1
  else
    if [ "$QUIET" -eq 0 ]; then printf "  ${GREEN}✓${NC} %s\n" "near-miss.json retains required landmines"; fi
    return 0
  fi
}

check_corpus_structure() {
  # All four corpus files must have valid JSON with a cases array
  local fail=0
  for f in deny.json near-miss.json quarantine.json skill-table.json; do
    local path="$CORPUS/$f"
    if [ ! -f "$path" ]; then
      printf "  ${RED}✗ %s missing${NC}\n" "$f"
      fail=1
      continue
    fi
    local err
    err=$(python3 -c "
import json
d = json.load(open('$path'))
if not isinstance(d, dict) or 'cases' not in d or not isinstance(d['cases'], list):
    print('missing cases array')
" 2>&1 || true)
    if [ -n "$err" ]; then
      printf "  ${RED}✗ %s: %s${NC}\n" "$f" "$err"
      fail=1
    else
      if [ "$QUIET" -eq 0 ]; then printf "  ${GREEN}✓${NC} %s: valid (cases array)\n" "$f"; fi
    fi
  done
  return $fail
}

check_test_target_isolation() {
  # Only RVCorpusTests may list 3+ module deps.
  # RVServiceTests and RVCLITests list 2 (RVPolicy as test fake) — warn, not fail.
  local pkg="$ROOT/Package.swift"
  if [ ! -f "$pkg" ]; then
    printf "  ${RED}✗ Package.swift missing${NC}\n"
    return 1
  fi
  local fail=0
  local output
  output=$(python3 -c "
import re, sys
content = open('$pkg').read()
pattern = r'\.testTarget\(\s*name:\s*\"([^\"]+)\"\s*,\s*dependencies:\s*\[([^\]]*)\]'
for m in re.finditer(pattern, content):
    name, deps_raw = m.group(1), m.group(2)
    deps = [d.strip().strip('\"') for d in deps_raw.split(',') if d.strip()]
    module_deps = [d for d in deps if not d.startswith('.')]
    if len(module_deps) >= 3 and name != 'RVCorpusTests':
        print(f'FAIL\t{name}\t{len(module_deps)} modules: {module_deps}')
    elif len(module_deps) == 2 and name not in ('RVCorpusTests', 'RVServiceTests', 'RVCLITests'):
        print(f'WARN\t{name}\t{len(module_deps)} modules: {module_deps}')
" 2>/dev/null || true)
  local fails warns
  fails=$(echo "$output" | grep '^FAIL' || true)
  warns=$(echo "$output" | grep '^WARN' || true)
  if [ -n "$fails" ]; then
    printf "  ${RED}✗ Test target with 3+ deps (only RVCorpusTests allowed)${NC}\n"
    echo "$fails" | sed 's/^/    /'
    fail=1
  fi
  if [ -n "$warns" ]; then
    printf "  ${YELLOW}⚠ Test target with 2 module deps${NC} (test fakes — review)\n"
    echo "$warns" | sed 's/^/    /'
    WARNINGS=$((WARNINGS + 1))
  fi
  if [ -z "$fails" ] && [ -z "$warns" ]; then
    if [ "$QUIET" -eq 0 ]; then printf "  ${GREEN}✓${NC} %s\n" "Test target isolation OK"; fi
  fi
  return $fail
}

# ─── Check registry ──────────────────────────────────────────────────────────

ALL_CHECKS=(
  value-types
  no-isdenied
  no-force-unwrap
  no-exported-import
  evaluate-pure
  no-bypass
  no-ns-home
  no-os-log-cmdtext
  name-hygiene
  no-xctest
  no-main-in-library
  graph-no-engine-packs
  corpus-quarantine
  corpus-landmines
  corpus-structure
  test-target-isolation
)

run_check() {
  case "$1" in
    value-types)            check_value_types ;;
    no-isdenied)            check_no_isdenied ;;
    no-force-unwrap)        check_no_force_unwrap ;;
    no-exported-import)     check_no_exported_import ;;
    evaluate-pure)          check_evaluate_pure ;;
    no-bypass)              check_no_bypass ;;
    no-ns-home)             check_no_ns_home ;;
    no-os-log-cmdtext)      check_no_os_log_cmdtext ;;
    name-hygiene)           check_name_hygiene ;;
    no-xctest)              check_no_xctest ;;
    no-main-in-library)     check_no_main_in_library ;;
    graph-no-engine-packs)  check_graph_no_engine_packs ;;
    corpus-quarantine)      check_corpus_quarantine ;;
    corpus-landmines)       check_corpus_landmines ;;
    corpus-structure)       check_corpus_structure ;;
    test-target-isolation)  check_test_target_isolation ;;
    *) echo "Unknown check: $1"; return 1 ;;
  esac
}

# ─── Main ─────────────────────────────────────────────────────────────────────

if [ "${1:-}" = "--list" ]; then
  print_list
  exit 0
fi

if [ "${1:-}" = "--check" ]; then
  if [ -z "${2:-}" ]; then
    echo "Usage: tools/preflight.sh --check NAME"
    echo "Run --list for available checks."
    exit 1
  fi
  run_check "$2"
  exit $?
fi

if [ "${1:-}" = "--quiet" ]; then
  QUIET=1
fi

printf "${CYAN}rv preflight${NC} — %d checks\n" "${#ALL_CHECKS[@]}"
printf "%s\n" "────────────────────────────────────────────────────────"

for check in "${ALL_CHECKS[@]}"; do
  if ! run_check "$check"; then
    FAILURES=$((FAILURES + 1))
  fi
done

printf "%s\n" "────────────────────────────────────────────────────────"
if [ "$FAILURES" -gt 0 ]; then
  printf "${RED}%d failed${NC}" "$FAILURES"
else
  printf "${GREEN}0 failed${NC}"
fi
if [ "$WARNINGS" -gt 0 ]; then
  printf ", ${YELLOW}%d warning%s${NC}" "$WARNINGS" "$([ "$WARNINGS" -ne 1 ] && echo s || true)"
fi
printf "\n"

exit $FAILURES
