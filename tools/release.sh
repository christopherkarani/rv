#!/usr/bin/env bash
# tools/release.sh — stage stripped C rv, Swift rv-cli, rvd, and pack bundles.
# Uses clang -Os for the C hook and tools/swift-6.3.3 for SPM products.
# Does not run swift package clean or wipe .build.
# Compatible with macOS /bin/bash 3.2.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SWIFT_WRAP="$ROOT/tools/swift-6.3.3"
STAGE="${RV_RELEASE_STAGE:-$ROOT/.build/release-stage}"
C_SRC="$ROOT/Sources/rv-c"

usage() {
  cat <<'EOF'
Usage: tools/release.sh

  clang -Os the C hook → stage as rv (stripped)
  swift build -c release --product rv → stage as rv-cli (strip -x)
  swift build -c release --product rvd → stage as rvd (strip -x)
  copy *_RVPacks.bundle into .build/release-stage
    (override with RV_RELEASE_STAGE)

Does not codesign. Does not write $HOME/.local/bin.
C is not an SPM product. SPM product rv stays the Swift operator (rv-cli).
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

OS="$(uname -s)"
ARCH="$(uname -m)"
CLANG_OS_FLAGS=()
case "$OS" in
  Darwin)
    if [[ "$ARCH" != "arm64" ]]; then
      printf "release: Apple Silicon only\n" >&2
      exit 1
    fi
    CLANG_OS_FLAGS=(-arch arm64 -mmacosx-version-min=26.0)
    ;;
  Linux)
    case "$ARCH" in
      aarch64|x86_64) ;;
      *)
        printf "release: Linux aarch64 or x86_64 only\n" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    printf "release: macOS 26 Apple Silicon, or Linux aarch64/x86_64\n" >&2
    exit 1
    ;;
esac

if [[ ! -x "$SWIFT_WRAP" ]]; then
  printf "release: missing executable %s\n" "$SWIFT_WRAP" >&2
  exit 1
fi

if [[ -z "$STAGE" || "$STAGE" == "/" || "$STAGE" == "$ROOT" ]]; then
  printf "release: refusing unsafe stage path %s\n" "${STAGE:-<empty>}" >&2
  exit 1
fi

if [[ ! -f "$C_SRC/rv.c" ]]; then
  printf "release: missing C hook sources in %s\n" "$C_SRC" >&2
  exit 1
fi

bash "$C_SRC/tests/run.sh"

rm -rf "$STAGE"
mkdir -p "$STAGE"

clang -Os "${CLANG_OS_FLAGS[@]}" -std=c11 -Wall \
  -I "$C_SRC" \
  -o "$STAGE/rv" \
  "$C_SRC/json_escape.c" \
  "$C_SRC/json_reply.c" \
  "$C_SRC/rv.c"
chmod 755 "$STAGE/rv"
if [[ "$OS" == "Darwin" ]]; then
  strip -x "$STAGE/rv"
  if otool -L "$STAGE/rv" | grep -E 'Foundation|CFNetwork' >/dev/null; then
    printf "release: C rv must not link Foundation or CFNetwork\n" >&2
    otool -L "$STAGE/rv" >&2
    exit 1
  fi
else
  strip "$STAGE/rv"
fi

set +e
"$SWIFT_WRAP" build -c release --product rv
rv_st=$?
set -e
if [[ "$rv_st" -ne 0 ]]; then
  printf "release: swift build --product rv failed (exit %s)\n" "$rv_st" >&2
  printf "Staged C rv at %s/rv (Swift rv-cli/rvd pending hookEvaluate dispatch)\n" "$STAGE" >&2
  ls -l "$STAGE/rv" >&2
  if [[ "$OS" == "Darwin" ]]; then
    otool -L "$STAGE/rv" >&2
  fi
  exit "$rv_st"
fi
BIN_DIR="$("$SWIFT_WRAP" build -c release --show-bin-path)"
if [[ ! -x "$BIN_DIR/rv" ]]; then
  printf "release: expected executable rv in %s\n" "$BIN_DIR" >&2
  exit 1
fi
cp "$BIN_DIR/rv" "$STAGE/rv-cli"
chmod 755 "$STAGE/rv-cli"
strip -x "$STAGE/rv-cli"

copied=0
for bundle in "$BIN_DIR"/*_RVPacks.bundle; do
  [[ -d "$bundle" ]] || continue
  name="$(basename "$bundle")"
  rm -rf "$STAGE/$name"
  cp -R "$bundle" "$STAGE/$name"
  copied=1
done

set +e
"$SWIFT_WRAP" build -c release --product rvd
rvd_st=$?
set -e
if [[ "$rvd_st" -ne 0 ]]; then
  printf "release: swift build --product rvd failed (exit %s)\n" "$rvd_st" >&2
  printf "Staged %s (rv C + rv-cli; rvd pending)\n" "$STAGE" >&2
  ls -l "$STAGE/rv" "$STAGE/rv-cli" >&2
  exit "$rvd_st"
fi

BIN_DIR="$("$SWIFT_WRAP" build -c release --show-bin-path)"
if [[ ! -x "$BIN_DIR/rvd" ]]; then
  printf "release: expected executable rvd in %s\n" "$BIN_DIR" >&2
  exit 1
fi
cp "$BIN_DIR/rvd" "$STAGE/rvd"
chmod 755 "$STAGE/rvd"
strip -x "$STAGE/rvd"

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
ls -l "$STAGE/rv" "$STAGE/rv-cli" "$STAGE/rvd"
for bundle in "$STAGE"/*_RVPacks.bundle; do
  [[ -d "$bundle" ]] || continue
  ls -ld "$bundle"
  du -sh "$bundle"
done
