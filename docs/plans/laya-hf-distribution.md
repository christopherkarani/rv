# Laya judge weights: Hugging Face distribution

Status: LIVE (2026-10-22). Weights are uploaded and pinned in the manifest:

- `karc14/rv-laya-ft-v2-coreml` @ `a71b1ce7cba9e795334ec60017a23c6488171ce8` (macOS production bundle)
- `karc14/rv-laya-ft-v2-onnx` @ `7b6ad83cd8bf4670f50bb31cac60d682d2280279` (held for the future Linux runtime)

A fresh install still runs packs-only until the user fetches; `rv doctor`
says so. This doc is the runbook.

## The pieces (all landed)

- [distribution-manifest.json](../Scripts/laya/distribution-manifest.json) —
  single source of truth. Per engine: install dir name, HF repo + revision
  (null until first upload), and every file with its SHA-256 and byte size,
  recorded at packaging time from `/tmp/laya-train/ft`.
- [hf-upload.py](../Scripts/laya/hf-upload.py) — stages the verified Ticket 5a
  artifacts plus a model card (same shape as the stock
  `aac6fef/laya-multilingual-coreml` card: Apache-2.0, `base_model` pointer,
  provenance, per-file hashes) and uploads one engine per repo. `--dry-run`
  stages and prints without touching the network.
- [fetch-models.sh](../Scripts/laya/fetch-models.sh) — downloads the pinned
  revision with curl, verifies SHA-256 + size per file, refuses on any
  mismatch, installs to `~/.config/rv/models/<bundle-dir>` (the exact dir
  `JudgeRuntime.expectedBundleDir` looks in). Fully offline afterwards.
- [JudgeModelDistributionTests.swift](../../Tests/RVServiceTests/JudgeModelDistributionTests.swift) —
  contract test: the manifest parses, engine names match the runtime's bundle
  dirs, every entry is well-formed, and the files the runtime requires
  (`model.mlpackage`, tokenizer, config) are all pinned.

## Owner step 1: upload (needs `HF_TOKEN` with write) — DONE 2026-10-22

```sh
python3 Scripts/laya/hf-upload.py --repo karc14/rv-laya-ft-v2-coreml --engine ft --dry-run
HF_TOKEN="$(cat ~/.config/hf-token)" python3 Scripts/laya/hf-upload.py --repo karc14/rv-laya-ft-v2-coreml --engine ft
HF_TOKEN="$(cat ~/.config/hf-token)" python3 Scripts/laya/hf-upload.py --repo karc14/rv-laya-ft-v2-onnx --engine onnx
```

Re-uploading (e.g. after retraining) writes the new `hf_revision` back into
the manifest — commit the manifest in the same commit (it is the pin).

## Owner step 2: verify on a clean HOME

```sh
HOME="$(mktemp -d)" Scripts/laya/fetch-models.sh --engine ft
HOME="<that dir>" rv doctor  # judge line should report the bundle
```

Then the normal rollout from the decision record still applies: recommend
`guard.mode: observe` first, judge reviews stay unlockable Asks.

## What users run (after step 1)

```sh
Scripts/laya/fetch-models.sh --engine ft
rv doctor
```

Size shown before download is ~649 MB (CoreML). `HF_REPO` / `HF_REVISION`
env vars override the manifest pins for testing, same as `export-onnx.sh`.

## Curl path (live 2026-10-22)

`install.sh` fetches the ft bundle on macOS curl installs (repo, revision,
and per-file hashes baked in, verified per file, best-effort — any failure
warns and the install continues packs-only). Skipped for local stages
(`RV_INSTALL_BIN`), with `RV_INSTALL_NO_MODELS=1`, when a bundle is already
installed, and on Linux. `InstallScriptTests.installSh_modelPinsMatchManifest`
keeps the baked pins identical to this manifest. The fetch lives in
`install.sh` deliberately, not `rv setup`: the ceremony owns search+wire
only (`Sources/RVPresentation/SetupCeremony.swift`).

## Not in this turn (follow-ups)

- Linux ONNX runtime in Swift (bundle is archived and pinned, but
  `JudgeRuntime` only runs CoreML — an ONNX-only dir still reads as
  packs-only, by design).
- Doctor naming the fetch command in its missing-bundle message.
