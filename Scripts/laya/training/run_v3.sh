#!/usr/bin/env bash
# Laya judge v3 runbook: rebuild v1/v2 -> generate -> dataset v3 -> proxy go/no-go
# -> fine-tune -> calibrate -> convert -> gate evaluation.
#
#   Scripts/laya/training/run_v3.sh                 # everything (resumes the fine-tune)
#   Scripts/laya/training/run_v3.sh finetune        # start at a step
#   Scripts/laya/training/run_v3.sh calibrate eval  # run only steps calibrate..eval
#
# Steps: lock tests v1 v2 gen prepare proxy finetune calibrate convert eval
# Variables (override in the environment):
#   LAYA_WORK       work root            (default ~/CodingProjects/laya-train-work)
#   VENV            python venv          (default $LAYA_WORK/venv)
#   SS11_DIR        ss11-{train,validation,test}.jsonl  (default $LAYA_WORK)
#   SHELLDATA       shell-safety medium split dir        (default $LAYA_WORK/shelldata/md)
#   HARNESS_REPORT  Swift harness measurements (door_*, latency) for eval, optional
#   PREP_ARGS       extra prepare_data_v3.py flags, e.g. "--block-target 0.16"
#   FT_ARGS         extra finetune_v3.py flags, e.g. "--epochs 4 --class-weights sqrt"
set -euo pipefail

export LAYA_WORK="${LAYA_WORK:-$HOME/CodingProjects/laya-train-work}"
VENV="${VENV:-$LAYA_WORK/venv}"
PY="$VENV/bin/python"
export SS11_DIR="${SS11_DIR:-$LAYA_WORK}"
export SHELLDATA="${SHELLDATA:-$LAYA_WORK/shelldata/md}"
export HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}"
export HF_HUB_DISABLE_XET=1
export TOKENIZERS_PARALLELISM=false
HARNESS_REPORT="${HARNESS_REPORT:-}"
PREP_ARGS="${PREP_ARGS:-}"
FT_ARGS="${FT_ARGS:-}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
mkdir -p "$LAYA_WORK/v3/logs"
LOG="$LAYA_WORK/v3/logs"

STEPS=(lock tests v1 v2 gen prepare proxy finetune calibrate convert eval)
FROM="${1:-lock}"
TO="${2:-eval}"
active=0

run() {  # run <step> <command...>  (tee'd to $LOG/<step>.log)
  local step="$1"; shift
  if [[ "$step" == "$FROM" ]]; then active=1; fi
  if [[ $active -eq 1 ]]; then
    echo "=== [$step] $* ($(date '+%H:%M:%S'))"
    "$@" 2>&1 | tee "$LOG/$step.log"
    local rc=${PIPESTATUS[0]}
    if [[ $rc -ne 0 ]]; then echo "=== [$step] FAILED (exit $rc); log $LOG/$step.log"; exit "$rc"; fi
  fi
  if [[ "$step" == "$TO" ]]; then echo "=== stopped after [$TO]"; exit 0; fi
}

printf '%s\n' "${STEPS[@]}" | grep -qx "$FROM" || { echo "unknown step $FROM (${STEPS[*]})"; exit 2; }
[[ -x "$PY" ]] || { echo "venv python missing: $PY"; exit 2; }

# 0. eval lock (every later script re-checks it)
run lock "$PY" lock_eval.py --check
run tests "$PY" -m pytest -q tests/

# 1. v1 from the raw shell-safety medium split (+ augment), then v2.
v1_build() {
  if [[ ! -f "$LAYA_WORK/v1/augment.jsonl" ]]; then
    LAYA_V1_BOOTSTRAP=1 "$PY" prepare_data.py   # base rows, so augment.py has its base texts
    "$PY" augment.py
  fi
  "$PY" prepare_data.py
}
run v1 v1_build
run v2 "$PY" prepare_data_v2.py

# 2. v3 data
run gen "$PY" gen_agent_v3.py
# shellcheck disable=SC2086
run prepare "$PY" prepare_data_v3.py $PREP_ARGS

# 3. cheap go/no-go before hours of MPS time
run proxy "$PY" proxy_tfidf_v3.py

# 4. fine-tune (resumable: re-running this step continues from ft/ckpt/latest.pt)
# shellcheck disable=SC2086
run finetune "$PY" finetune_v3.py --resume $FT_ARGS

# 5. temperature + thresholds
run calibrate "$PY" calibrate_v3.py

# 6. CoreML / ONNX fp16 bundle (drift + size gates), writes ft/convert-report.json
run convert "$PY" convert_ft.py --version v3

# 7. ship gates (exit 1 if any gate fails)
EXT=(--external "$LAYA_WORK/v3/ft/convert-report.json")
if [[ -n "$HARNESS_REPORT" ]]; then EXT+=(--external "$HARNESS_REPORT"); fi
run eval "$PY" eval_v3.py "${EXT[@]}"
