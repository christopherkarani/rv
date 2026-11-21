#!/usr/bin/env bash
# Resumes the Laya judge harness (LayaEvalHarnessTests) until every corpus
# row has both contexts recorded. A crash (abort) is logged with the row it
# hit, then the run resumes there. macOS only, with a judge bundle installed;
# see Scripts/laya/eval/README.md.
#
# Env: RV_LAYA_EVAL_OUT_DIR (default Scripts/laya/eval/out), SWIFT (default
# Scripts/swift-6.4 when present, else swift on PATH). Build the tests first
# (`swift build --build-tests`): each attempt runs with --skip-build.
set -u
cd "$(dirname "$0")/../../.."
DIR=Scripts/laya/eval
OUT_DIR=${RV_LAYA_EVAL_OUT_DIR:-$DIR/out}
case "$OUT_DIR" in /*) ;; *) OUT_DIR="$PWD/$OUT_DIR" ;; esac
mkdir -p "$OUT_DIR"
export RV_LAYA_EVAL_OUT_DIR="$OUT_DIR"
if [ -z "${SWIFT:-}" ]; then
  if [ -x Scripts/swift-6.4 ]; then SWIFT=Scripts/swift-6.4; else SWIFT=swift; fi
fi
OUT=$OUT_DIR/results.jsonl
touch "$OUT"
TOTAL=$(python3 -I -c "import json,sys;print(len(json.load(open(sys.argv[1]))))" "$DIR/corpus.json")
LOG=$OUT_DIR/drive.log
for attempt in $(seq 1 30); do
  # Drop a half-written pair (one context only) so pairs stay aligned.
  LINES=$(wc -l < "$OUT"); if [ $(( LINES % 2 )) -ne 0 ]; then sed -i '' '$d' "$OUT"; fi
  DONE=$(( $(wc -l < "$OUT") / 2 ))
  [ "$DONE" -ge "$TOTAL" ] && { echo "complete $DONE" >> "$LOG"; exit 0; }
  echo "attempt $attempt start=$DONE $(date +%T)" >> "$LOG"
  RV_LAYA_EVAL=1 RV_LAYA_EVAL_START=$DONE timeout 5000 $SWIFT test --skip-build --filter LayaEvalHarness \
    > "$OUT_DIR/run-$attempt.log" 2>&1
  rc=$?
  if grep -q "failed assertion" "$OUT_DIR/run-$attempt.log"; then
    echo "  CRASH rc=$rc at $(grep laya-eval-at "$OUT_DIR/run-$attempt.log" | tail -1) :: $(grep 'failed assertion' "$OUT_DIR/run-$attempt.log" | sed 's/.*failed assertion/failed assertion/')" >> "$LOG"
  else
    echo "  exit rc=$rc" >> "$LOG"
  fi
done
echo "gave up after 30 attempts" >> "$LOG"
exit 1
