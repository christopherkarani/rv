#!/usr/bin/env bash
# Scripts/release-assets.sh — rename a release stage into per-target
# GitHub release assets. Staged/installed filenames never change; only
# the published asset names carry the target suffix, so one release can
# hold every platform: rv-darwin-arm64, rv-linux-x86_64, and so on.
# Compatible with macOS /bin/bash 3.2.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: Scripts/release-assets.sh <stage-dir> <out-dir> <target>

  <target> is darwin-arm64, linux-aarch64, or linux-x86_64.
  Copies rv, rv-cli, rvd, rv-workspace-host (plus rv-pty-claim and
  rv-isolation-exec when staged) to <out-dir>/<name>-<target>, copies
  libswiftCompatibilitySpan.dylib under its plain name when staged, tars
  the staged *_RVPacks bundle/resources directory as
  rv_RVPacks-<target>.tar.gz, and (Linux targets only) tars the staged
  Swift runtime libraries as rv-swiftlibs-<target>.tar.gz.
EOF
}

if [[ $# -ne 3 ]]; then
  usage >&2
  exit 2
fi

STAGE="$1"
OUT="$2"
TARGET="$3"

case "$TARGET" in
  darwin-arm64|linux-aarch64|linux-x86_64) ;;
  *)
    printf 'release-assets: target must be darwin-arm64, linux-aarch64, or linux-x86_64, not %s\n' "$TARGET" >&2
    exit 2
    ;;
esac

if [[ ! -d "$STAGE" ]]; then
  printf 'release-assets: stage directory missing: %s\n' "$STAGE" >&2
  exit 1
fi

mkdir -p "$OUT"

for name in rv rv-cli rvd rv-workspace-host; do
  if [[ ! -x "$STAGE/$name" ]]; then
    printf 'release-assets: expected executable %s in %s\n' "$name" "$STAGE" >&2
    exit 1
  fi
  cp "$STAGE/$name" "$OUT/$name-$TARGET"
  chmod 755 "$OUT/$name-$TARGET"
done

for name in rv-pty-claim rv-isolation-exec; do
  if [[ -x "$STAGE/$name" ]]; then
    cp "$STAGE/$name" "$OUT/$name-$TARGET"
    chmod 755 "$OUT/$name-$TARGET"
  fi
done

if [[ -f "$STAGE/libswiftCompatibilitySpan.dylib" ]]; then
  cp "$STAGE/libswiftCompatibilitySpan.dylib" "$OUT/libswiftCompatibilitySpan.dylib"
  chmod 755 "$STAGE/libswiftCompatibilitySpan.dylib"
fi

if [[ "$TARGET" == linux-* ]]; then
  lib_names=()
  for lib in "$STAGE"/*.so; do
    [[ -f "$lib" ]] || continue
    lib_names+=("$(basename "$lib")")
  done
  if [[ "${#lib_names[@]}" -eq 0 ]]; then
    printf 'release-assets: Linux %s needs Swift runtime libraries in %s\n' "$TARGET" "$STAGE" >&2
    exit 1
  fi
  tar -czf "$OUT/rv-swiftlibs-$TARGET.tar.gz" -C "$STAGE" "${lib_names[@]}"
fi

packed=0
for bundle in "$STAGE"/*_RVPacks.bundle "$STAGE"/*_RVPacks.resources; do
  [[ -d "$bundle" ]] || continue
  tar -czf "$OUT/rv_RVPacks-$TARGET.tar.gz" -C "$STAGE" "$(basename "$bundle")"
  packed=1
done

if [[ "$packed" -eq 0 ]]; then
  printf 'release-assets: no *_RVPacks bundle or resources in %s\n' "$STAGE" >&2
  exit 1
fi

printf 'Release assets for %s in %s\n' "$TARGET" "$OUT"
ls -l "$OUT"
