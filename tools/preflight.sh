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
# Requires: bash, grep, find, sed, python3 (for corpus + Package.swift structural checks).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCES="$ROOT/Sources"
TESTS="$ROOT/Tests"
CORPUS="$TESTS/RVEngineTests/Fixtures/corpus"

# Declare hidden dependencies up front so the checks fail loudly, not silently.
# corpus-quarantine, corpus-landmines, and test-target-isolation delegate to
# python3; if it is missing the empty result must NOT read as "no violations".
command -v python3 >/dev/null 2>&1 || {
  printf "preflight: python3 required (corpus + Package.swift checks)\n" >&2
  exit 127
}
for _d in "$SOURCES" "$TESTS"; do
  [ -d "$_d" ] || { printf "preflight: missing expected directory %s\n" "$_d" >&2; exit 1; }
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

QUIET=0
FAILURES=0
WARNINGS=0

print_list() {
  cat <<'EOF'
Available checks:
  value-types           No class/actor outside RVService/RVPolicy/RVAnalytics (store modules)
  no-isdenied           No boolean isDenied anywhere in Sources
  no-force-unwrap       No try! or force-unwrap (!) on production paths
  no-exported-import    No new @_exported import (existing T1 debt is known)
  evaluate-pure         RVEngine evaluate has no Date(), FileManager, or ProcessInfo
  no-bypass             No RV_BYPASS or env that skips evaluate
  no-ns-home             No NSHomeDirectory() in Sources or Tests
  no-os-log-cmdtext     No command text written to os_log (structural check)
  name-hygiene          No leftover dcg/ryk tokens outside docs/factory/ (rykanv brand/domain allowed)
  one-cli-surface       README/help must not list rv-cli as a command
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

# Indent stdin by four spaces. Used for diagnostic detail under ✗/⚠ lines.
# (shellcheck SC2001 prefers ${var//...} but that does not prefix multi-line.)
indent() { sed 's/^/    /'; }

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
    if [ "$QUIET" -eq 0 ]; then printf "  %b✓%b %s\n" "$GREEN" "$NC" "$label"; fi
    return 0
  else
    printf "  %b✗ %s%b (%d match%s)\n" "$RED" "$label" "$NC" "$count" "$([ "$count" -ne 1 ] && echo es || true)"
    if [ "$QUIET" -eq 0 ]; then
      echo "$matches" | head -15 | indent
      [ "$count" -gt 15 ] && echo "    … ($(( count - 15 )) more)"
    fi
    return 1
  fi
}

# ─── Checks ──────────────────────────────────────────────────────────────────

check_value_types() {
  # Reference types (class, actor) outside the allowed edges.
  #   class  — only RVService (the XPC/NSObject edge).
  #   actor  — only RVService, RVPolicy, and RVAnalytics (store modules; AGENTS allows
  #            "actors for stores"). Domain/Engine/Packs/Presentation are value-only.
  # A leading attribute (@MainActor, @objc, @unchecked Sendable, …) or access
  # modifier (public/internal/…/final) must not hide a declaration, so we match
  # the keyword on a line that may start with any run of those tokens.
  local pat='^\s*(@[A-Za-z][A-Za-z0-9_ ]*\s)?(public |internal |private |fileprivate |open |final )*(class|actor) '
  local matches
  matches=$(grep -rnE "$pat" "$SOURCES" --include='*.swift' \
    | grep -v 'Sources/RVService/' | grep -v 'Sources/RVPolicy/' | grep -v 'Sources/RVAnalytics/' || true)
  local count
  count=$(echo "$matches" | grep -c . || true)
  if [ "$count" -eq 0 ]; then
    if [ "$QUIET" -eq 0 ]; then printf "  %b✓%b %s\n" "$GREEN" "$NC" "No class/actor outside RVService/RVPolicy/RVAnalytics"; fi
    return 0
  else
    printf "  %b✗ class/actor outside RVService/RVPolicy/RVAnalytics%b (%d)\n" "$RED" "$NC" "$count"
    echo "$matches" | head -15 | indent
    return 1
  fi
}

check_no_isdenied() {
  check_empty "No boolean isDenied" 'isDenied' "$SOURCES" --include='*.swift'
}

check_no_force_unwrap() {
  # try! and force-unwrap (!) on production paths (AGENTS: "No try! / !").
  # The `!` form excludes != and !== so we catch optional! but not inequality.
  # Uses grep -E (ERE) because the pattern needs alternation + char class.
  local fail=0
  check_empty "No try! in Sources" 'try!' "$SOURCES" --include='*.swift' || fail=1
  local matches
  matches=$(grep -rnE '[]A-Za-z0-9_)}]!([^=]|$)' "$SOURCES" --include='*.swift' 2>/dev/null || true)
  local count
  count=$(echo "$matches" | grep -c . || true)
  if [ "$count" -eq 0 ]; then
    if [ "$QUIET" -eq 0 ]; then printf "  %b✓%b %s\n" "$GREEN" "$NC" "No force-unwrap (!) in Sources"; fi
  else
    printf "  %b✗ force-unwrap (!) in Sources%b (%d)\n" "$RED" "$NC" "$count"
    echo "$matches" | head -15 | indent
    fail=1
  fi
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
    if [ "$QUIET" -eq 0 ]; then printf "  %b✓%b %s\n" "$GREEN" "$NC" "No @_exported import"; fi
    return 0
  fi
  # Check if all matches are in RVEngine.swift or RVPacks.swift (known T1 debt)
  local non_debt
  non_debt=$(echo "$matches" | grep -v 'RVEngine.swift:' | grep -v 'RVPacks.swift:' || true)
  local non_debt_count
  non_debt_count=$(echo "$non_debt" | grep -c . || true)
  if [ "$non_debt_count" -gt 0 ]; then
    printf "  %b✗ New @_exported import outside known T1 debt%b (%d)\n" "$RED" "$NC" "$non_debt_count"
    echo "$non_debt" | head -10 | indent
    return 1
  else
    printf "  %b⚠ @_exported import%b (%d, known T1 debt in RVEngine/RVPacks)\n" "$YELLOW" "$NC" "$count"
    WARNINGS=$((WARNINGS + 1))
    return 0
  fi
}

check_evaluate_pure() {
  # Functional core: only RVEngine's evaluate must be pure. RVCLI/RVService are
  # the imperative shell and may touch Date/FileManager/ProcessInfo.
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
    if [ "$QUIET" -eq 0 ]; then printf "  %b✓%b %s\n" "$GREEN" "$NC" "No os_log usage (no command-text risk)"; fi
    return 0
  else
    printf "  %b⚠ os_log/Logger usage%b (%d site%s — verify no command text)\n" "$YELLOW" "$NC" "$count" "$([ "$count" -ne 1 ] && echo s || true)"
    if [ "$QUIET" -eq 0 ]; then
      echo "$matches" | head -10 | indent
    fi
    WARNINGS=$((WARNINGS + 1))
    return 0
  fi
}

check_name_hygiene() {
  # PLAN #20: no dcg or ryk tokens outside docs/factory/ in product files.
  # Product exception (Chris): rykanv / Rykan V / rykanv.com are brand/domain,
  # not leftover ryk. A line whose only hit is inside those forms is allowed.
  # Bare ryk (CLI/product name), .ryk policy paths, and dcg still FAIL.
  #
  # Two tiers:
  #   FAIL  — leftover token in product code (any tracked file under ROOT
  #           except the excluded paths below). Scanning the whole tree (not
  #           a hardcoded file allowlist) means a NEW root file (CHANGELOG.md,
  #           install script, …) is covered automatically.
  #   WARN  — token in agent-config dotfiles (.ryk, .claude-plugin, .agents)
  #           These are pre-existing multi-tool configs, not product code, but
  #           worth surfacing so an agent doesn't "clean up" what looks stray.
  #
  # Excludes: .build, .git, .worktrees (worktree copies are not product files),
  # docs/factory (allowed), tools/preflight.sh (self — must contain the tokens),
  # tools/README.md (documents the tokens), .gitignore (path reference).
  #
  # Uses POSIX grep (not rg) so there is no hidden ripgrep dependency.
  # python3 (already required above) strips the allowed brand/domain forms
  # so rykanv does not count as the ryk substring.

  # Product files: whole tree, narrowed by extension, minus known-OK paths.
  local product_raw
  product_raw=$(grep -rni 'dcg\|ryk' \
    "$ROOT" \
    --include='*.swift' --include='*.md' --include='*.json' --include='*.sh' --include='Package.swift' \
    2>/dev/null \
    | grep -v '/.build/' | grep -v '/.git/' | grep -v '/.worktrees/' \
    | grep -v '/docs/factory/' \
    | grep -v 'tools/preflight.sh' | grep -v 'tools/README.md' \
    | grep -v '/.ryk/' | grep -v '/.claude-plugin/' | grep -v '/.agents/' \
    | grep -v '/.skynex/' \
    | grep -v '\.gitignore' || true)
  local product_matches err
  product_matches=$(printf '%s\n' "$product_raw" | python3 -c '
import re, sys
brand = re.compile(r"(?i)(?<![a-z])(?:rykanv(?:\.com)?|rykan[ \t]+v)(?![a-z])")
leftover = re.compile(r"(?i)dcg|ryk")
files = set()
for raw in sys.stdin:
    line = raw.rstrip("\n")
    if not line:
        continue
    path, sep, rest = line.partition(":")
    if not sep:
        continue
    _, sep2, text = rest.partition(":")
    body = text if sep2 else rest
    if leftover.search(brand.sub("", body)):
        files.add(path)
for path in sorted(files):
    print(path)
' 2>&1) || err=1
  if [ "${err:-0}" = 1 ]; then
    printf "  %b✗ Name hygiene: brand-allow filter failed%b\n" "$RED" "$NC"
    echo "$product_matches" | indent
    return 1
  fi
  local pcount
  pcount=$(echo "$product_matches" | grep -c . || true)

  # Agent config dotfiles: warn only.
  local config_matches
  config_matches=$(grep -rli 'dcg\|ryk' \
    "$ROOT/.claude-plugin" "$ROOT/.agents" "$ROOT/.ryk" \
    2>/dev/null \
    | grep -v '/.build/' || true)
  local ccount
  ccount=$(echo "$config_matches" | grep -c . || true)

  if [ "$pcount" -gt 0 ]; then
    printf "  %b✗ Name hygiene: dcg/ryk in product files%b (%d)\n" "$RED" "$NC" "$pcount"
    echo "$product_matches" | head -15 | indent
    return 1
  fi
  if [ "$ccount" -gt 0 ]; then
    printf "  %b⚠ dcg/ryk in agent-config dotfiles%b (%d, pre-existing — not product code)\n" "$YELLOW" "$NC" "$ccount"
    WARNINGS=$((WARNINGS + 1))
  fi
  if [ "$QUIET" -eq 0 ]; then printf "  %b✓%b %s\n" "$GREEN" "$NC" "Name hygiene: no dcg/ryk in product files"; fi
  return 0
}

check_one_cli_surface() {
  # PLAN #25: only user command is rv. On-disk operator name may live in
  # install/C/doctor internals. README and help catalogs must not tell a
  # human to type rv-cli.
  local matches
  matches=$(grep -n 'rv-cli' \
    "$ROOT/README.md" \
    "$SOURCES/RVCLI/Help/HelpCatalog.swift" \
    2>/dev/null || true)
  local count
  count=$(printf '%s\n' "$matches" | grep -c . || true)
  if [ "$count" -gt 0 ]; then
    printf "  %b✗ One CLI surface: rv-cli in README or help%b (%d)\n" "$RED" "$NC" "$count"
    echo "$matches" | head -10 | indent
    return 1
  fi
  if [ "$QUIET" -eq 0 ]; then printf "  %b✓%b %s\n" "$GREEN" "$NC" "One CLI surface: README/help do not list rv-cli"; fi
  return 0
}

check_no_xctest() {
  # Word-boundary: avoid matching import XCTestHelper / import XCTestMocks.
  check_empty "Tests use Swift Testing, not XCTest" 'import XCTest$' "$TESTS" --include='*.swift'
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
    printf "  %b✗ main.swift in library target%b (%d)\n" "$RED" "$NC" "$count"
    echo "$matches" | head -10 | indent
    fail=1
  else
    if [ "$QUIET" -eq 0 ]; then printf "  %b✓%b %s\n" "$GREEN" "$NC" "No main.swift in library targets"; fi
  fi
  # @main in library target source files
  local amatches
  amatches=$(grep -rn '@main' "$SOURCES" --include='*.swift' \
    | grep -v 'Sources/rv/' | grep -v 'Sources/rvd/' || true)
  local acount
  acount=$(echo "$amatches" | grep -c . || true)
  if [ "$acount" -gt 0 ]; then
    printf "  %b✗ @main in library target%b (%d)\n" "$RED" "$NC" "$acount"
    echo "$amatches" | head -10 | indent
    fail=1
  fi
  return $fail
}

check_graph_no_engine_packs() {
  check_empty "RVEngine does not import RVPacks" 'import RVPacks' "$SOURCES/RVEngine" --include='*.swift'
}

check_corpus_quarantine() {
  # Never quarantine reset-hard or fork-bomb. Match the COMMAND field only, with
  # word boundaries, so a note like "reset-hardening" does not false-positive
  # (the previous version substring-matched the whole serialized case object).
  local fail=0
  local qfile="$CORPUS/quarantine.json"
  if [ ! -f "$qfile" ]; then
    printf "  %b✗ quarantine.json missing%b\n" "$RED" "$NC"
    return 1
  fi
  local found err
  found=$(python3 -c "
import json, re
d = json.load(open('$qfile'))
for c in d.get('cases', []):
    cmd = c.get('command', '').lower()
    for token in ('reset-hard', 'fork-bomb'):
        # token-boundary match: not a substring of a larger word
        if re.search(r'(^|[^a-z-])' + re.escape(token) + r'([^a-z-]|\$)', cmd):
            print(c.get('id', '?'))
            break
" 2>&1) || err=1
  if [ "${err:-0}" = 1 ]; then
    printf "  %b✗ quarantine.json: python parse failed%b\n" "$RED" "$NC"
    echo "$found" | indent
    return 1
  fi
  local count
  count=$(echo "$found" | grep -c . || true)
  if [ "$count" -gt 0 ]; then
    printf "  %b✗ reset-hard/fork-bomb in quarantine.json%b (%d)\n" "$RED" "$NC" "$count"
    echo "$found" | indent
    return 1
  else
    if [ "$QUIET" -eq 0 ]; then printf "  %b✓%b %s\n" "$GREEN" "$NC" "reset-hard/fork-bomb not in quarantine"; fi
    return 0
  fi
}

check_corpus_landmines() {
  # near-miss.json must retain required allow landmine commands.
  # These are the rows agents keep deleting to go green (SKILL landmines.md).
  local nfile="$CORPUS/near-miss.json"
  if [ ! -f "$nfile" ]; then
    printf "  %b✗ near-miss.json missing%b\n" "$RED" "$NC"
    return 1
  fi
  local missing err
  missing=$(python3 -c "
import json, re
d = json.load(open('$nfile'))
cmds = [c.get('command','').lower() for c in d.get('cases', [])]
# Each required landmine must appear as a distinct token in the command,
# not as a substring of another word (e.g. 'rg' must not match 'cargo').
required = [
    'force-with-lease',
    'checkout -b',
    'restore',
    'rg',
]
for r in required:
    # Word-boundary regex: the token must be preceded/followed by a non-word
    # char (space, quote, start/end). This prevents 'rg' matching 'cargo'.
    pattern = r'(^|[^a-z])' + re.escape(r) + r'([^a-z]|\$)'
    if not any(re.search(pattern, cmd) for cmd in cmds):
        print(r)
" 2>&1) || err=1
  if [ "${err:-0}" = 1 ]; then
    printf "  %b✗ near-miss.json: python parse failed%b\n" "$RED" "$NC"
    echo "$missing" | indent
    return 1
  fi
  local count
  count=$(echo "$missing" | grep -c . || true)
  if [ "$count" -gt 0 ]; then
    printf "  %b✗ near-miss.json missing required landmine commands%b (%d)\n" "$RED" "$NC" "$count"
    echo "$missing" | indent
    return 1
  else
    if [ "$QUIET" -eq 0 ]; then printf "  %b✓%b %s\n" "$GREEN" "$NC" "near-miss.json retains required landmines"; fi
    return 0
  fi
}

check_corpus_structure() {
  # All four corpus files must have valid JSON with a cases array
  local fail=0
  for f in deny.json near-miss.json quarantine.json skill-table.json; do
    local path="$CORPUS/$f"
    if [ ! -f "$path" ]; then
      printf "  %b✗ %s missing%b\n" "$RED" "$f" "$NC"
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
      printf "  %b✗ %s: %s%b\n" "$RED" "$f" "$err" "$NC"
      fail=1
    else
      if [ "$QUIET" -eq 0 ]; then printf "  %b✓%b %s: valid (cases array)\n" "$GREEN" "$NC" "$f"; fi
    fi
  done
  return $fail
}

check_test_target_isolation() {
  # Only RVCorpusTests may list 3+ module deps.
  # RVServiceTests and RVCLITests list 2 (RVPolicy as test fake) — warn, not fail.
  local pkg="$ROOT/Package.swift"
  if [ ! -f "$pkg" ]; then
    printf "  %b✗ Package.swift missing%b\n" "$RED" "$NC"
    return 1
  fi
  local fail=0
  local output err
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
" 2>&1) || err=1
  if [ "${err:-0}" = 1 ]; then
    printf "  %b✗ Package.swift: python parse failed%b\n" "$RED" "$NC"
    echo "$output" | indent
    return 1
  fi
  local fails warns
  fails=$(echo "$output" | grep '^FAIL' || true)
  warns=$(echo "$output" | grep '^WARN' || true)
  if [ -n "$fails" ]; then
    printf "  %b✗ Test target with 3+ deps (only RVCorpusTests allowed)%b\n" "$RED" "$NC"
    echo "$fails" | indent
    fail=1
  fi
  if [ -n "$warns" ]; then
    printf "  %b⚠ Test target with 2 module deps%b (test fakes — review)\n" "$YELLOW" "$NC"
    echo "$warns" | indent
    WARNINGS=$((WARNINGS + 1))
  fi
  if [ -z "$fails" ] && [ -z "$warns" ]; then
    if [ "$QUIET" -eq 0 ]; then printf "  %b✓%b %s\n" "$GREEN" "$NC" "Test target isolation OK"; fi
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
  one-cli-surface
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
    one-cli-surface)        check_one_cli_surface ;;
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
elif [ -n "${1:-}" ]; then
  echo "Unknown flag: $1" >&2
  echo "Usage: tools/preflight.sh [--quiet | --check NAME | --list]" >&2
  exit 1
fi

printf "%brv preflight%b — %d checks\n" "$CYAN" "$NC" "${#ALL_CHECKS[@]}"
printf "%s\n" "────────────────────────────────────────────────────────"

for check in "${ALL_CHECKS[@]}"; do
  if ! run_check "$check"; then
    FAILURES=$((FAILURES + 1))
  fi
done

printf "%s\n" "────────────────────────────────────────────────────────"
if [ "$FAILURES" -gt 0 ]; then
  printf "%b%d failed%b" "$RED" "$FAILURES" "$NC"
else
  printf "%b0 failed%b" "$GREEN" "$NC"
fi
if [ "$WARNINGS" -gt 0 ]; then
  printf ", %b%d warning%s%b" "$YELLOW" "$WARNINGS" "$([ "$WARNINGS" -ne 1 ] && echo s || true)" "$NC"
fi
printf "\n"

exit $FAILURES
