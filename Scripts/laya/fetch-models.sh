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
    --engine) ENGINE="$2"; shift 2 ;;
    --dest) DEST="$2"; shift 2 ;;
    *) echo "unknown flag: $1 (want --engine ft|onnx [--dest DIR])" >&2; exit 2 ;;
  esac
done

case "$ENGINE" in
  ft|onnx) ;;
  *) echo "missing or unknown --engine (want ft|onnx)" >&2; exit 2 ;;
esac

command -v python3 >/dev/null 2>&1 || { echo "fetch-models: python3 required" >&2; exit 127; }
command -v curl >/dev/null 2>&1 || { echo "fetch-models: curl required" >&2; exit 127; }

# Resolve repo + revision + file list from the manifest (env wins, like export-onnx.sh).
MANIFEST_OUT="$(HF_REPO="${HF_REPO:-}" HF_REVISION="${HF_REVISION:-}" MANIFEST="$MANIFEST" ENGINE="$ENGINE" python3 - <<'EOF'
import json, os, shlex
m = json.load(open(os.environ["MANIFEST"]))
eng = m["engines"][os.environ["ENGINE"]]
repo = os.environ["HF_REPO"] or eng.get("hf_repo")
rev = os.environ["HF_REVISION"] or eng.get("hf_revision")
if not repo or not rev:
    raise SystemExit(f"no HF repo/revision pinned for engine {os.environ['ENGINE']}; "
                     "run hf-upload.py first or pass HF_REPO + HF_REVISION")
print(f"REPO={shlex.quote(repo)}")
print(f"REV={shlex.quote(rev)}")
print(f"BUNDLE_DIR={shlex.quote(eng['bundle_dir'])}")
for f in eng["files"]:
    print(f"NEED_FILE {shlex.quote(f['path'])} {f['sha256']} {f['bytes']}")
EOF
)"
eval "$(printf '%s\n' "$MANIFEST_OUT" | grep -E '^(REPO|REV|BUNDLE_DIR)=')"

if [ -z "$DEST" ]; then
  : "${HOME:?HOME is required}"
  DEST="$HOME/.config/rv/models/$BUNDLE_DIR"
fi
mkdir -p "$DEST"

tmp_list="$(mktemp)"
trap 'rm -f "$tmp_list"' EXIT
printf '%s\n' "$MANIFEST_OUT" | grep '^NEED_FILE ' | sed 's/^NEED_FILE //' > "$tmp_list"

total=0
echo "fetching $REPO @ $REV into $DEST"
while read -r rel want_hash want_bytes; do
  [ -n "$rel" ] || continue
  out="$DEST/$rel"
  mkdir -p "$(dirname "$out")"
  # HF_BASE_URL override exists for offline tests only (local file tree or
  # stub server); default is always huggingface.co.
  curl -fsSL "${HF_BASE_URL:-https://huggingface.co}/$REPO/resolve/$REV/$rel" -o "$out.tmp"
  got_hash="$(shasum -a 256 "$out.tmp" | awk '{print $1}')"
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

echo "installed $ENGINE bundle: $total bytes in $DEST"
echo "verify with: rv doctor"
