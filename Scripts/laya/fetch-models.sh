#!/bin/sh
# Fetch a pinned Laya judge bundle from Hugging Face into the rv models dir.
# Verifies SHA-256 per file against Scripts/laya/distribution-manifest.json
# and refuses on any mismatch. Fully offline afterwards.
#
# Supply-chain contract (docs/plans/laya-guard-model-plan.md): the repo and
# revision come from the committed manifest (filled by hf-upload.py); only
# weights/tokenizer/config JSON + markdown are downloaded, never code.
# Override pins only via the env vars below, and update them in the manifest
# in the same commit.
#
# Usage: Scripts/laya/fetch-models.sh --engine ft [--dest DIR]
#        HF_REPO=owner/name HF_REVISION=<sha> Scripts/laya/fetch-models.sh --engine ft
set -eu

ENGINE=""
DEST=""
MANIFEST="$(cd "$(dirname "$0")" && pwd)/distribution-manifest.json"

while [ $# -gt 0 ]; do
  case "$1" in
    --engine) ENGINE="${2:?want --engine ft|onnx}"; shift 2 ;;
    --dest) DEST="${2:?want --dest DIR}"; shift 2 ;;
    *) echo "unknown flag: $1 (want --engine ft|onnx [--dest DIR])" >&2; exit 2 ;;
  esac
done

case "$ENGINE" in
  ft|onnx) ;;
  *) echo "missing or unknown --engine (want ft|onnx)" >&2; exit 2 ;;
esac

command -v python3 >/dev/null 2>&1 || { echo "fetch-models: python3 required" >&2; exit 127; }
command -v curl >/dev/null 2>&1 || { echo "fetch-models: curl required" >&2; exit 127; }

# Hash tool: macOS ships shasum (perl), minimal Linux images only sha256sum.
if command -v sha256sum >/dev/null 2>&1; then
  sha256_file() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  echo "fetch-models: sha256sum or shasum required" >&2; exit 127
fi

# Resolve repo + revision + file list from the manifest (env wins, like export-onnx.sh).
MANIFEST_OUT="$(HF_REPO="${HF_REPO:-}" HF_REVISION="${HF_REVISION:-}" MANIFEST="$MANIFEST" ENGINE="$ENGINE" python3 - <<'EOF'
import json, os, shlex
m = json.load(open(os.environ["MANIFEST"]))
if m.get("version") != 1:
    raise SystemExit(f"unsupported distribution-manifest version: {m.get('version')!r} (want 1)")
eng = m["engines"][os.environ["ENGINE"]]
repo = os.environ["HF_REPO"] or eng.get("hf_repo")
rev = os.environ["HF_REVISION"] or eng.get("hf_revision")
if not repo or not rev:
    raise SystemExit(f"no HF repo/revision pinned for engine {os.environ['ENGINE']}; "
                     "run hf-upload.py first or pass HF_REPO + HF_REVISION")
print(f"REPO={shlex.quote(repo)}")
print(f"REV={shlex.quote(rev)}")
print(f"BUNDLE_DIR={shlex.quote(eng['bundle_dir'])}")
if os.environ["HF_REPO"] or os.environ["HF_REVISION"]:
    print("PIN_SRC=env")
else:
    print("PIN_SRC=manifest")
for f in eng["files"]:
    print(f"NEED_FILE {shlex.quote(f['path'])} {f['sha256']} {f['bytes']}")
EOF
)"
eval "$(printf '%s\n' "$MANIFEST_OUT" | grep -E '^(REPO|REV|BUNDLE_DIR|PIN_SRC)=')"

if [ -z "$DEST" ]; then
  : "${HOME:?HOME is required}"
  DEST="$HOME/.config/rv/models/$BUNDLE_DIR"
fi
mkdir -p "$(dirname "$DEST")"
# Stage beside DEST (same filesystem, so the final move is an atomic
# rename) and swap only after every file verifies. Downloading straight
# into DEST would leave a version-mixed bundle when a re-fetch is
# interrupted, and health checks only test existence — the mixed bundle
# would read as healthy while weights/tokenizer/config disagree.
stage="$(mktemp -d "$(dirname "$DEST")/.rv-fetch.XXXXXX")"

tmp_list="$(mktemp)"
trap 'rm -f "$tmp_list"; rm -rf "$stage"' EXIT
printf '%s\n' "$MANIFEST_OUT" | grep '^NEED_FILE ' | sed 's/^NEED_FILE //' > "$tmp_list"

total=0
echo "fetching $REPO @ $REV into $DEST (pins from $PIN_SRC)"
while read -r line; do
  [ -n "$line" ] || continue
  eval "set -- $line"
  rel=$1; want_hash=$2; want_bytes=$3
  out="$stage/$rel"
  mkdir -p "$(dirname "$out")"
  # HF_BASE_URL override exists for offline tests only (local file tree or
  # stub server); default is always huggingface.co.
  curl -fsSL --connect-timeout 15 --speed-limit 1000 --speed-time 60 \
    "${HF_BASE_URL:-https://huggingface.co}/$REPO/resolve/$REV/$rel" -o "$out.tmp"
  got_hash="$(sha256_file "$out.tmp")"
  got_bytes="$(wc -c < "$out.tmp" | tr -d ' \n')"
  if [ "$got_hash" != "$want_hash" ]; then
    echo "fetch-models: SHA-256 mismatch for $rel" >&2
    echo "  got  $got_hash" >&2
    echo "  want $want_hash" >&2
    rm -f "$out.tmp"
    exit 1
  fi
  if [ "$got_bytes" != "$want_bytes" ]; then
    echo "fetch-models: size mismatch for $rel (got $got_bytes, want $want_bytes)" >&2
    rm -f "$out.tmp"
    exit 1
  fi
  mv "$out.tmp" "$out"
  total=$((total + got_bytes))
  echo "  ok $rel ($got_bytes bytes)"
done < "$tmp_list"

rm -rf "$DEST"
mv "$stage" "$DEST"

echo "installed $ENGINE bundle: $total bytes in $DEST"
echo "verify with: rv doctor"
