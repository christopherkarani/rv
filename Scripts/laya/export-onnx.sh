#!/bin/sh
# Build rv's ONNX bundle from the pinned upstream Laya checkpoint.
# NOTE: no Swift ONNX runtime is wired yet (the CoreML judge is the
# shipping path); this produces the artifact for the future Linux
# runtime. The export prints the max logit difference vs PyTorch -
# do not ship a bundle whose diff is not ~1e-5 class.
#
# Supply-chain contract (docs/plans/laya-guard-model-plan.md): every
# input that gets executed is pinned and verified BEFORE it runs -
# git commit SHA, HF revision SHA, exact pip versions. Override pins
# only via the env vars below, and update them here in the same commit.
#
# Usage: Scripts/laya/export-onnx.sh [multilingual|english] [out-dir]
set -eu

LAYA_GIT_SHA="${LAYA_GIT_SHA:-60d5ee6ef8e731646e8ca9ac0139d25fcf4fa295}"
VARIANT="${1:-multilingual}"
OUT="${2:-build/laya-onnx-$VARIANT}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

case "$VARIANT" in
  multilingual)
    HF_REPO="convaiinnovations/laya-multilingual"
    HF_REVISION="${HF_REVISION:-1720e3e3357cfe1e281542e223f8273b0890ca34}"
    ;;
  english)
    HF_REPO="convaiinnovations/laya"
    HF_REVISION="${HF_REVISION:-7b928d828b7b0e022f929d9bd2e44165aa270148}"
    ;;
  *) echo "unknown variant: $VARIANT" >&2; exit 2 ;;
esac
export HF_REPO HF_REVISION

# Fetch exactly the pinned commit and verify before running its code.
git init -q "$WORK/receptron-laya"
git -C "$WORK/receptron-laya" remote add origin https://github.com/receptron/laya
git -C "$WORK/receptron-laya" fetch -q --depth 1 origin "$LAYA_GIT_SHA"
git -C "$WORK/receptron-laya" checkout -q --detach FETCH_HEAD
actual="$(git -C "$WORK/receptron-laya" rev-parse HEAD)"
if [ "$actual" != "$LAYA_GIT_SHA" ]; then
  echo "pinned git sha mismatch: got $actual want $LAYA_GIT_SHA" >&2
  exit 1
fi

cd "$WORK/receptron-laya/export"
uv venv .venv --python 3.13 -q
# Exact versions this export was verified with (training env record).
uv pip install -p .venv/bin/python \
  torch==2.14.1 transformers==5.20.1 safetensors==0.8.0 \
  onnx==1.23.2 onnxscript==0.7.2 onnxruntime==1.31.0 \
  huggingface_hub==1.33.0
# Repo/revision arrive via the environment, never shell interpolation.
HF_HUB_DISABLE_XET=1 .venv/bin/python -c "
import os
from huggingface_hub import snapshot_download
snapshot_download(
    os.environ['HF_REPO'],
    revision=os.environ['HF_REVISION'],
    local_dir='model',
    allow_patterns=['model.safetensors', 'encoder/*', 'tokenizer/*',
                    'rl_agent_config.json', 'rl_common.py', 'rl_agent_api.py'],
)
print('downloaded', os.environ['HF_REPO'], '@', os.environ['HF_REVISION'])
"
mkdir -p "$OLDPWD/$OUT"
.venv/bin/python export_onnx.py model "$OLDPWD/$OUT"
cd "$OLDPWD/$OUT"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum laya.onnx laya.onnx.data laya_config.json tokenizer/tokenizer.json | tee SHA256SUMS
else
  shasum -a 256 laya.onnx laya.onnx.data laya_config.json tokenizer/tokenizer.json | tee SHA256SUMS
fi
echo "bundle at $OUT - record these hashes with the pins before shipping"
