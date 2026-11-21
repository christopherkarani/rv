#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <repo-path> [--build] [--filter PATTERN] [--traits TRAITS] [--omit-integration-targets]" >&2
  exit 2
}

[[ $# -ge 1 ]] || usage
repo="$1"
shift
mode="test"
filter=""
traits=""
omit_integration=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) mode="build"; shift ;;
    --filter) [[ $# -ge 2 ]] || usage; filter="$2"; shift 2 ;;
    --traits) [[ $# -ge 2 ]] || usage; traits="$2"; shift 2 ;;
    --omit-integration-targets) omit_integration=1; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

[[ -d "$repo" ]] || { echo "Repository does not exist: $repo" >&2; exit 2; }
scratch="$(mktemp -d -t swift-pr-orchestration.XXXXXX)"
module_cache="$scratch/module-cache"
mkdir -p "$module_cache"

swift_args=()
if [[ "$mode" == "build" ]]; then
  swift_args+=(build)
else
  swift_args+=(test --no-parallel)
fi
swift_args+=(--package-path "$repo" --scratch-path "$scratch")
if [[ -n "$traits" ]]; then swift_args+=(--traits "$traits"); fi
if [[ -n "$filter" && "$mode" == "test" ]]; then swift_args+=(--filter "$filter"); fi

echo "Running: ${swift_args[*]}"
if [[ "$omit_integration" == 1 ]]; then
  SWARM_OMIT_INTEGRATION_TARGETS=1 \
    CLANG_MODULE_CACHE_PATH="$module_cache" \
    SWIFT_MODULECACHE_PATH="$module_cache" \
    swift "${swift_args[@]}"
else
  CLANG_MODULE_CACHE_PATH="$module_cache" \
    SWIFT_MODULECACHE_PATH="$module_cache" \
    swift "${swift_args[@]}"
fi
