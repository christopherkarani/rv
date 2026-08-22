#!/usr/bin/env bash
# tools/release.sh — stage stripped release rv + rvd + pack resource bundles.
# Uses tools/swift-6.3.3. Does not run swift package clean or wipe .build.
# Compatible with macOS /bin/bash 3.2.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SWIFT_WRAP="$ROOT/tools/swift-6.3.3"
STAGE="${RV_RELEASE_STAGE:-$ROOT/.build/release-stage}"

usage() {
  cat <<'EOF'
Usage: tools/release.sh

  swift build -c release --product rv
  swift build -c release --product rvd
  strip -x the two products
  stage rv, rvd, and *_RVPacks.bundle into .build/release-stage
    (override with RV_RELEASE_STAGE)

Does not codesign. Does not write $HOME/.local/bin.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf "release: unknown option %s\n" "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -x "$SWIFT_WRAP" ]]; then
  printf "release: missing executable %s\n" "$SWIFT_WRAP" >&2
  exit 1
fi

if [[ -z "$STAGE" || "$STAGE" == "/" || "$STAGE" == "$ROOT" ]]; then
  printf "release: refusing unsafe stage path %s\n" "${STAGE:-<empty>}" >&2
  exit 1
fi

# Two invocations: a single command with two --product flags builds only the last.
"$SWIFT_WRAP" build -c release --product rv
"$SWIFT_WRAP" build -c release --product rvd

BIN_DIR="$("$SWIFT_WRAP" build -c release --show-bin-path)"
if [[ ! -x "$BIN_DIR/rv" || ! -x "$BIN_DIR/rvd" ]]; then
  printf "release: expected executable rv and rvd in %s\n" "$BIN_DIR" >&2
  exit 1
fi

rm -rf "$STAGE"
mkdir -p "$STAGE"

cp "$BIN_DIR/rv" "$STAGE/rv"
cp "$BIN_DIR/rvd" "$STAGE/rvd"
chmod 755 "$STAGE/rv" "$STAGE/rvd"
strip -x "$STAGE/rv" "$STAGE/rvd"

copied=0
for bundle in "$BIN_DIR"/*_RVPacks.bundle; do
  [[ -d "$bundle" ]] || continue
  name="$(basename "$bundle")"
  rm -rf "$STAGE/$name"
  cp -R "$bundle" "$STAGE/$name"
  copied=1
done

if [[ "$copied" -eq 0 ]]; then
  printf "release: no *_RVPacks.bundle next to products in %s\n" "$BIN_DIR" >&2
  exit 1
fi

printf "Staged %s\n" "$STAGE"
ls -l "$STAGE/rv" "$STAGE/rvd"
for bundle in "$STAGE"/*_RVPacks.bundle; do
  [[ -d "$bundle" ]] || continue
  ls -ld "$bundle"
  du -sh "$bundle"
done
