#!/usr/bin/env bash
# Scripts/release.sh — stage stripped C rv, Swift rv-cli, rvd, and pack bundles.
# Uses clang -Os for the C hook and Scripts/swift-6.4 for SPM products.
# Does not run swift package clean or wipe .build.
# Compatible with macOS /bin/bash 3.2.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SWIFT_WRAP="$ROOT/Scripts/swift-6.4"
STAGE="${RV_RELEASE_STAGE:-$ROOT/.build/release-stage}"
C_SRC="$ROOT/Sources/rv-c"

usage() {
  cat <<'EOF'
Usage: Scripts/release.sh

  clang -Os the C hook → stage as rv (stripped)
  swift build -c release --product rv → stage as rv-cli (strip -x)
  swift build -c release --product rvd → stage as rvd (strip -x)
  copy *_RVPacks.bundle (Darwin) or *_RVPacks.resources (Linux)
    into .build/release-stage (override with RV_RELEASE_STAGE)

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
    CLANG_OS_FLAGS=(-arch arm64 -mmacosx-version-min=15.0)
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
    printf "release: macOS 15 Apple Silicon, or Linux aarch64/x86_64\n" >&2
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

# Contained Linux launches require this trusted sibling before any agent work.
if [[ "$OS" == "Linux" ]]; then
  "$SWIFT_WRAP" build -c release --product rv-isolation-exec
  cp "$BIN_DIR/rv-isolation-exec" "$STAGE/rv-isolation-exec"
  chmod 755 "$STAGE/rv-isolation-exec"
  strip "$STAGE/rv-isolation-exec"
fi

copied=0
# Darwin SPM emits *_RVPacks.bundle; Linux SPM emits *_RVPacks.resources.
# Bundle.module looks next to the relocated binary, then a baked .build path.
for bundle in "$BIN_DIR"/*_RVPacks.bundle "$BIN_DIR"/*_RVPacks.resources; do
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

"$SWIFT_WRAP" build -c release --product rv-workspace-host
if [[ ! -x "$BIN_DIR/rv-workspace-host" ]]; then
  printf "release: expected executable rv-workspace-host in %s\n" "$BIN_DIR" >&2
  exit 1
fi
cp "$BIN_DIR/rv-workspace-host" "$STAGE/rv-workspace-host"
chmod 755 "$STAGE/rv-workspace-host"
strip -x "$STAGE/rv-workspace-host"

# Contained Darwin PTY launches exec this sibling before sandbox-exec.
# The host looks it up next to its own binary. Do not ship the host without it.
if [[ "$OS" == "Darwin" ]]; then
  "$SWIFT_WRAP" build -c release --product rv-pty-claim
  BIN_DIR="$("$SWIFT_WRAP" build -c release --show-bin-path)"
  if [[ ! -x "$BIN_DIR/rv-pty-claim" ]]; then
    printf "release: expected executable rv-pty-claim in %s\n" "$BIN_DIR" >&2
    exit 1
  fi
  cp "$BIN_DIR/rv-pty-claim" "$STAGE/rv-pty-claim"
  chmod 755 "$STAGE/rv-pty-claim"
  strip -x "$STAGE/rv-pty-claim"

  needs_span=0
  for staged in "$STAGE/rv-cli" "$STAGE/rvd" "$STAGE/rv-workspace-host" "$STAGE/rv-pty-claim"; do
    if otool -L "$staged" | grep -q 'libswiftCompatibilitySpan.dylib'; then
      needs_span=1
    fi
  done
  if [[ "$needs_span" -eq 1 ]]; then
    runtime_resource="$("$SWIFT_WRAP" -print-target-info | python3 -c 'import json,sys; print(json.load(sys.stdin)["paths"]["runtimeResourcePath"])')"
    swift_lib_root="$(cd "$(dirname "$runtime_resource")" && pwd)"
    span_runtime=""
    for candidate in "$swift_lib_root"/swift-*/macosx/libswiftCompatibilitySpan.dylib; do
      [[ -f "$candidate" ]] || continue
      span_runtime="$candidate"
      break
    done
    if [[ -z "$span_runtime" ]]; then
      printf 'release: Swift binaries require libswiftCompatibilitySpan.dylib, but it is missing from the Swift toolchain\n' >&2
      exit 1
    fi
    cp "$span_runtime" "$STAGE/libswiftCompatibilitySpan.dylib"
    chmod 755 "$STAGE/libswiftCompatibilitySpan.dylib"
    mkdir -p "$STAGE/rv-agent-shims"
    cp "$ROOT"/AgentShims/claude "$ROOT"/AgentShims/codex "$ROOT"/AgentShims/muse "$ROOT"/AgentShims/opencode "$STAGE/rv-agent-shims/"
    chmod 755 "$STAGE"/rv-agent-shims/claude "$STAGE"/rv-agent-shims/codex "$STAGE"/rv-agent-shims/muse "$STAGE"/rv-agent-shims/opencode
    for staged in "$STAGE/rv-cli" "$STAGE/rvd" "$STAGE/rv-workspace-host" "$STAGE/rv-pty-claim"; do
      if ! otool -L "$staged" | grep -q 'libswiftCompatibilitySpan.dylib'; then
        continue
      fi
      if ! otool -l "$staged" | grep -A3 'cmd LC_RPATH' | grep -Fq 'path @loader_path '; then
        install_name_tool -add_rpath @loader_path "$staged"
      fi
    done
  fi
fi

for bundle in "$BIN_DIR"/*_RVPacks.bundle "$BIN_DIR"/*_RVPacks.resources; do
  [[ -d "$bundle" ]] || continue
  name="$(basename "$bundle")"
  rm -rf "$STAGE/$name"
  cp -R "$bundle" "$STAGE/$name"
  copied=1
done

if [[ "$copied" -eq 0 ]]; then
  printf "release: no *_RVPacks.bundle or *_RVPacks.resources next to products in %s\n" "$BIN_DIR" >&2
  exit 1
fi

if [[ "$OS" == "Darwin" ]]; then
  for staged in "$STAGE/rv" "$STAGE/rv-cli" "$STAGE/rvd" "$STAGE/rv-workspace-host"; do
    show="$(vtool -show-build "$staged")"
    printf '%s\n' "$show" | grep -q 'minos 15.0' || {
      printf 'release: %s minos is not 15.0\n%s\n' "$staged" "$show" >&2
      exit 1
    }
  done
  if otool -L "$STAGE/rv-cli" | grep -E 'libswiftCore|FoundationModels' | grep -q '@rpath'; then
    printf 'release: rv-cli must link the OS Swift runtime, not an @rpath toolchain\n' >&2
    otool -L "$STAGE/rv-cli" >&2
    exit 1
  fi
  if nm -u "$STAGE/rv-cli" | grep -q '_swift_initBorrow'; then
    printf 'release: rv-cli references _swift_initBorrow, unavailable on macOS 26\n' >&2
    exit 1
  fi
fi

printf "Staged %s\n" "$STAGE"
ls -l "$STAGE/rv" "$STAGE/rv-cli" "$STAGE/rvd" "$STAGE/rv-workspace-host"
if [[ "$OS" == "Darwin" ]]; then
  ls -l "$STAGE/rv-pty-claim"
fi
for bundle in "$STAGE"/*_RVPacks.bundle "$STAGE"/*_RVPacks.resources; do
  [[ -d "$bundle" ]] || continue
  ls -ld "$bundle"
  du -sh "$bundle"
done
