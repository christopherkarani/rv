#!/bin/sh
# Build rv's own ONNX bundle from the pinned upstream Laya checkpoint
# (Linux judge runtime, Phase 3). Uses receptron/laya's exporter as the
# starting point; the export itself prints the max logit difference vs
# PyTorch - do not ship a bundle whose diff is not ~1e-5 class.
#
# Usage: Scripts/laya/export-onnx.sh [multilingual|english] [out-dir]
set -eu

VARIANT="${1:-multilingual}"
OUT="${2:-build/laya-onnx-$VARIANT}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

case "$VARIANT" in
  multilingual) HF_REPO="convaiinnovations/laya-multilingual" ;;
  english)      HF_REPO="convaiinnovations/laya" ;;
  *) echo "unknown variant: $VARIANT" >&2; exit 2 ;;
esac

git clone --depth 1 https://github.com/receptron/laya "$WORK/receptron-laya"
cd "$WORK/receptron-laya/export"
uv venv .venv --python 3.13 -q
uv pip install -p .venv/bin/python torch transformers safetensors onnx onnxscript onnxruntime huggingface_hub
HF_HUB_DISABLE_XET=1 .venv/bin/python -c \
  "from huggingface_hub import snapshot_download; snapshot_download('$HF_REPO', local_dir='model', allow_patterns=['model.safetensors','encoder/*','tokenizer/*','rl_agent_config.json','rl_common.py','rl_agent_api.py'])"
mkdir -p "$OLDPWD/$OUT"
.venv/bin/python export_onnx.py model "$OLDPWD/$OUT"
cd "$OLDPWD/$OUT"
shasum -a 256 laya.onnx laya.onnx.data laya_config.json tokenizer/tokenizer.json | tee SHA256SUMS
echo "bundle at $OUT - pin these hashes before shipping"
