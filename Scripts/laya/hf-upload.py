#!/usr/bin/env python3
"""Upload the fine-tuned Laya judge to Hugging Face (one engine per repo).

Packages the verified Ticket 5a artifacts with a model card and uploads
them, then pins the repo + revision back into distribution-manifest.json
(the file Scripts/laya/fetch-models.sh and the contract test read).

Follows the same shape as the stock bundle already in use
(aac6fef/laya-multilingual-coreml): Apache-2.0 card, base_model pointer,
provenance section, per-file hashes.

Supply-chain contract (docs/plans/laya-guard-model-plan.md): nothing that
gets executed is downloaded here — this script only READS local artifacts
and PUSHES weights + JSON + markdown. Requires HF_TOKEN (write) in env.

Usage:
  python3 Scripts/laya/hf-upload.py --repo <owner>/<name> --engine ft [--source /tmp/laya-train/ft]
  python3 Scripts/laya/hf-upload.py --repo <owner>/<name>-onnx --engine onnx
  python3 Scripts/laya/hf-upload.py --repo <owner>/<name> --engine ft --dry-run  # stage + print, no network
"""

import argparse
import hashlib
import json
import shutil
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
MANIFEST_PATH = HERE / "distribution-manifest.json"
DEFAULT_SOURCE = Path("/tmp/laya-train/ft")

BASE_MODEL = "convaiinnovations/laya-multilingual"
BASE_REVISION = "1720e3e3357cfe1e281542e223f8273b0890ca34"


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def stage_files(engine: str, source: Path, staging: Path) -> list:
    """Copy the distributable files for one engine into staging. Returns
    [(repo_path, sha256, bytes)]."""
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    try:
        wanted = [f["path"] for f in manifest["engines"][engine]["files"]]
    except KeyError:
        raise SystemExit(f"unknown engine in manifest: {engine}")
    src_root = source / "coreml" if engine == "ft" else source
    out = []
    for rel in wanted:
        src = src_root / rel
        if not src.is_file():
            raise SystemExit(f"missing artifact: {src}")
        dst = staging / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        out.append((rel, sha256(dst), dst.stat().st_size))
    return out


def model_card(engine: str, repo: str, staged: list) -> str:
    lines = [
        "---",
        "license: apache-2.0",
        "library_name: coreml" if engine == "ft" else "library_name: onnx",
        "pipeline_tag: text-classification",
        f"base_model: {BASE_MODEL}",
        "tags:",
        "- laya",
        "- rv",
        "- decision-model",
        "- local-ai",
    ]
    if engine == "ft":
        lines += ["- coreml", "- apple-silicon"]
    else:
        lines += ["- onnx", "- linux"]
    lines += [
        "---",
        "",
        f"# {repo.split('/')[-1]}",
        "",
        "Fine-tuned Laya judge for rv: shell commands in, allow / review /",
        "block out. Single forward pass, no generated text. Runs fully offline",
        "once downloaded.",
        "",
        "## Install for rv",
        "",
        "```sh",
        "Scripts/laya/fetch-models.sh --engine " + engine,
        "# verifies SHA-256 per file, installs to ~/.config/rv/models/",
        "rv doctor  # judge line should report the bundle",
        "```",
        "",
        "## Provenance",
        "",
        f"- Base checkpoint: `{BASE_MODEL}` at `{BASE_REVISION}`.",
        "- Fine-tune data: shell-safety v1.1 (MIT) + v2 context serialization",
        "  (train hash d8e153ea, validation hash 5cd0c2b0).",
        "- Exam scores (torch fp32): shell held 36/36 kept 33/35,",
        "  adversarial held 18/19, incidents held 12/13, ko held 17/21.",
        "- Known miss preserved at p~1.0: `git add -A` (covered by rv packs",
        "  in the full system). Context at runtime is command + cwd only",
        "  (partial vs training); no production-traffic accuracy is claimed.",
        "- Original Laya weights and code are by Convai Innovations and",
        "  contributors, Apache-2.0. This is a fine-tune, not an official",
        "  Convai Innovations release.",
        "",
        "## Files",
        "",
    ]
    for rel, digest, size in staged:
        lines.append(f"- `{rel}` — {size} bytes, SHA-256 `{digest}`")
    lines += [
        "",
        "See `config.json` (`checkpoint: laya-ft-v2-fp16`) for label order,",
        "max length, and training hashes.",
        "",
    ]
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--repo", required=True, help="owner/name of the HF repo")
    ap.add_argument("--engine", required=True, choices=["ft", "onnx"])
    ap.add_argument("--source", default=str(DEFAULT_SOURCE))
    ap.add_argument("--staging", default=None,
                    help="staging root (default: a fresh mkdtemp)")
    ap.add_argument("--private", action="store_true", help="create a private repo")
    ap.add_argument("--dry-run", action="store_true", help="stage + print, no upload")
    args = ap.parse_args()

    source = Path(args.source)
    if args.staging:
        staging = Path(args.staging) / args.engine
        if staging.exists():
            shutil.rmtree(staging)
    else:
        staging = Path(tempfile.mkdtemp(prefix="laya-hf-stage-")) / args.engine
    staging.mkdir(parents=True)

    staged = stage_files(args.engine, source, staging)
    (staging / "README.md").write_text(
        model_card(args.engine, args.repo, staged), encoding="utf-8"
    )
    total = sum(s for _, _, s in staged)
    print(f"staged {len(staged)} files, {total / 1e6:.1f} MB in {staging}")
    for rel, digest, size in staged:
        print(f"  {digest[:12]}  {size:>12}  {rel}")

    if args.dry_run:
        print("dry-run: no upload, manifest untouched")
        return 0

    try:
        from huggingface_hub import create_repo, upload_folder
        from huggingface_hub import repo_info as hub_repo_info
    except ImportError:
        print("huggingface_hub required: pip install huggingface_hub", file=sys.stderr)
        return 2

    create_repo(args.repo, exist_ok=True, private=args.private)
    upload_folder(repo_id=args.repo, folder_path=str(staging))
    revision = hub_repo_info(args.repo).sha
    print(f"uploaded {args.repo} @ {revision}")

    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    manifest["engines"][args.engine]["hf_repo"] = args.repo
    manifest["engines"][args.engine]["hf_revision"] = revision
    manifest["engines"][args.engine]["files"] = [
        {"path": rel, "sha256": digest, "bytes": size}
        for rel, digest, size in staged
    ]
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"manifest updated: {MANIFEST_PATH}")
    print("next: commit the manifest, then verify with fetch-models.sh --engine "
          f"{args.engine} on a clean HOME")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
