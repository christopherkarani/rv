#!/usr/bin/env python3
"""One-shot extract of core.git + core.filesystem JSON from a local v0.11.0 tree.

Usage:
  python3 tools/extract-packs/extract_core_packs.py --source-root /path/to/checkout

The checkout must already be at tag v0.11.0 / commit
2ed7eeef1ae63d204495f02312c657dd6d9bf73d. This script does not clone, curl,
or vendor Rust into the product tree.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

PINNED_COMMIT = "2ed7eeef1ae63d204495f02312c657dd6d9bf73d"
PINNED_VERSION = "0.11.0"

# Product-tree name hygiene: never emit the two forbidden factory tokens.
_FORBIDDEN = re.compile(
    chr(100) + chr(99) + chr(103) + "|" + chr(114) + chr(121) + chr(107),
    re.IGNORECASE,
)

GIT_SAFE_NAMES = [
    "checkout-new-branch",
    "checkout-orphan",
    "restore-staged-long",
    "restore-staged-short",
    "clean-dry-run-short",
    "clean-dry-run-long",
]
GIT_DESTRUCTIVE_NAMES = [
    "git-alias-semantic-unverified",
    "branch-dynamic-token",
    "checkout-discard",
    "checkout-ref-discard",
    "restore-worktree",
    "restore-worktree-explicit",
    "reset-hard",
    "reset-merge",
    "clean-force",
    "push-force-long",
    "push-force-short",
    "branch-force-delete",
    "stash-drop",
    "stash-clear",
]
FS_SAFE_NAMES = [
    "rm-rf-tmp",
    "rm-fr-tmp",
    "rm-rf-var-tmp",
    "rm-fr-var-tmp",
    "rm-r-f-tmp",
    "rm-f-r-tmp",
    "rm-r-f-var-tmp",
    "rm-f-r-var-tmp",
    "rm-recursive-force-tmp",
    "rm-force-recursive-tmp",
    "rm-recursive-force-var-tmp",
    "rm-force-recursive-var-tmp",
    "find-delete-tmp",
    "find-delete-var-tmp",
    "unlink-tmp",
    "unlink-var-tmp",
    "unlink-help",
    "truncate-help",
    "truncate-grow",
    "truncate-tmp",
    "truncate-var-tmp",
    "shred-help",
    "shred-tmp",
    "shred-var-tmp",
    "tar-remove-files-tmp",
    "tar-remove-files-var-tmp",
    "dd-tmp",
    "dd-var-tmp",
    "dd-help",
    "mv-tmp",
    "mv-var-tmp",
    "mv-help",
    "mv-to-trash",
]
FS_DESTRUCTIVE_NAMES = [
    "sed-exec-unverified",
    "cp-sensitive-then-delete",
    "ln-symlink-sensitive-then-delete",
    "rsync-sensitive-then-delete",
    "rm-rf-root-home",
    "rm-r-f-separate-root-home",
    "rm-recursive-force-root-home",
    "rm-rf-general",
    "rm-glob-home",
    "rm-r-f-separate",
    "rm-recursive-force-long",
    "find-delete-root-home",
    "find-delete-general",
    "unlink-root-home",
    "unlink-general",
    "truncate-zero-root-home",
    "truncate-zero-general",
    "shred-root-home",
    "shred-general",
    "tar-remove-files-root-home",
    "tar-remove-files-general",
    "dd-overwrite-root-home",
    "dd-overwrite-general",
    "mv-sensitive-source-root-home",
    "mv-dynamic-path",
    "redirect-truncate-root-home",
    "redirect-truncate-dynamic-path",
    "fork-bomb",
]

GIT_ALIAS_REASON = (
    "The invoked Git alias depends on shell expansion, contains a cycle, or "
    "exceeds the engine's bounded semantic analysis."
)
GIT_ALIAS_EXPLANATION = (
    "Review the fully expanded Git executable, alias chain, shell-alias body, "
    "and appended arguments before allowing execution. Dynamic shell values, "
    "cycles, and commands beyond the semantic parser's bounds can hide "
    "destructive operations."
)
BRANCH_DYNAMIC_REASON = (
    "A dynamic shell expansion in this git branch command can expand into a "
    "deletion or forced ref update. Quote the branch name or add `--` to make "
    "it a literal creation."
)


def hygiene(text: str) -> str:
    cleaned = _FORBIDDEN.sub("the engine", text)
    cleaned = cleaned.replace("the engine's", "the engine's")
    cleaned = re.sub(r"the engine rebase-recover", "rv allow-once", cleaned)
    cleaned = re.sub(r"`the engine rebase-recover`", "`rv allow-once`", cleaned)
    if _FORBIDDEN.search(cleaned):
        raise SystemExit(f"name hygiene failed: {cleaned!r}")
    return cleaned


def decode_rust_string(literal: str) -> str:
    if literal.startswith("r"):
        hashes = 0
        i = 1
        while i < len(literal) and literal[i] == "#":
            hashes += 1
            i += 1
        if i >= len(literal) or literal[i] != '"':
            raise ValueError(f"bad raw string: {literal[:40]!r}")
        end = literal.rfind('"' + ("#" * hashes))
        return literal[i + 1 : end]
    if literal.startswith('"'):
        body = literal[1:-1]
        return (
            body.replace(r"\n", "\n")
            .replace(r"\t", "\t")
            .replace(r"\"", '"')
            .replace(r"\\", "\\")
        )
    raise ValueError(f"not a string literal: {literal[:40]!r}")


def read_string(src: str, i: int) -> tuple[str, int]:
    while i < len(src) and src[i] in " \t\n\r":
        i += 1
    if i >= len(src):
        raise ValueError("eof looking for string")
    if src.startswith("r#", i) or src.startswith('r"', i):
        j = i + 1
        hashes = 0
        if src[i] == "r":
            while j < len(src) and src[j] == "#":
                hashes += 1
                j += 1
        if j >= len(src) or src[j] != '"':
            raise ValueError(f"bad raw at {i}")
        j += 1
        close = '"' + ("#" * hashes)
        k = src.find(close, j)
        if k < 0:
            raise ValueError("unclosed raw string")
        return src[i : k + len(close)], k + len(close)
    if src[i] == '"':
        j = i + 1
        while j < len(src):
            if src[j] == "\\" and j + 1 < len(src):
                j += 2
                continue
            if src[j] == '"':
                return src[i : j + 1], j + 1
            j += 1
        raise ValueError("unclosed string")
    raise ValueError(f"expected string at {i}: {src[i : i + 20]!r}")


def skip_ws_and_comments(src: str, i: int) -> int:
    while i < len(src):
        if src[i] in " \t\n\r":
            i += 1
            continue
        if src.startswith("//", i):
            nl = src.find("\n", i)
            i = len(src) if nl < 0 else nl + 1
            continue
        if src.startswith("/*", i):
            end = src.find("*/", i + 2)
            i = len(src) if end < 0 else end + 2
            continue
        break
    return i


def skip_concat_strings(src: str, i: int) -> tuple[str, int]:
    """Read one or more adjacent Rust string literals joined by whitespace or `\\`."""
    parts: list[str] = []
    while True:
        i = skip_ws_and_comments(src, i)
        if i < len(src) and src[i] == "\\":
            i = skip_ws_and_comments(src, i + 1)
        if i >= len(src) or src[i] not in '"r':
            break
        if src[i] == "r" and i + 1 < len(src) and src[i + 1] not in '"#':
            break
        lit, i = read_string(src, i)
        parts.append(decode_rust_string(lit))
        i = skip_ws_and_comments(src, i)
        if i < len(src) and src[i] == "\\":
            continue
        # Adjacent literals without comma continue the same argument.
        if i < len(src) and src[i] in '"r':
            continue
        break
    return "".join(parts), i


def parse_macro_args(src: str, start: int) -> tuple[list[object], int]:
    """Parse arguments of safe_pattern! / destructive_pattern! starting at '('."""
    assert src[start] == "("
    i = start + 1
    args: list[object] = []
    while True:
        i = skip_ws_and_comments(src, i)
        if i >= len(src):
            raise ValueError("unclosed macro")
        if src[i] == ")":
            return args, i + 1
        if src[i] == ",":
            i += 1
            continue
        if src.startswith("executables", i):
            end = src.find("]", i)
            i = end + 1 if end >= 0 else i + 1
            continue
        if src[i] in '"r':
            text, i = skip_concat_strings(src, i)
            args.append(text)
            continue
        if src[i].isalpha():
            j = i
            while j < len(src) and (src[j].isalnum() or src[j] == "_"):
                j += 1
            ident = src[i:j]
            if ident in {"Critical", "High", "Medium", "Low"}:
                args.append(("severity", ident.lower()))
                i = j
                continue
            # suggestion constant or other ident — skip to comma or close
            i = j
            continue
        if src[i] == "&":
            # skip &const { ... } or &IDENT
            depth = 0
            while i < len(src):
                if src[i] == "{":
                    depth += 1
                elif src[i] == "}":
                    depth -= 1
                    if depth == 0:
                        i += 1
                        break
                elif src[i] in ",)" and depth == 0:
                    break
                i += 1
            continue
        i += 1


def extract_macros(src: str, kind: str) -> list[dict]:
    needle = f"{kind}!("
    out: list[dict] = []
    start = 0
    while True:
        idx = src.find(needle, start)
        if idx < 0:
            break
        paren = idx + len(needle) - 1
        args, end = parse_macro_args(src, paren)
        start = end
        strings = [a for a in args if isinstance(a, str)]
        severity = next(
            (a[1] for a in args if isinstance(a, tuple) and a[0] == "severity"),
            None,
        )
        if kind == "safe_pattern":
            if len(strings) < 2:
                raise SystemExit(f"safe_pattern needs name+pattern, got {strings!r}")
            out.append(
                {
                    "name": strings[0],
                    "pattern": strings[1],
                    "description": strings[2] if len(strings) > 2 else "",
                }
            )
        else:
            if len(strings) < 3:
                raise SystemExit(f"destructive_pattern needs name+pattern+reason, got {strings!r}")
            item = {
                "name": strings[0],
                "pattern": strings[1],
                "severity": severity or "high",
                "description": hygiene(strings[2]),
            }
            if len(strings) > 3:
                item["explanation"] = hygiene(collapse_ws(strings[3]))
            out.append(item)
    return out


def collapse_ws(text: str) -> str:
    # Keep paragraph breaks; squeeze indent from Rust line continuations.
    lines = [re.sub(r"[ \t]+", " ", line).strip() for line in text.splitlines()]
    paragraphs: list[str] = []
    buf: list[str] = []
    for line in lines:
        if not line:
            if buf:
                paragraphs.append(" ".join(buf))
                buf = []
            continue
        buf.append(line)
    if buf:
        paragraphs.append(" ".join(buf))
    return "\n\n".join(paragraphs)


def inject_git_semantic(items: list[dict]) -> list[dict]:
    existing = {i["name"] for i in items}
    semantic = [
        {
            "name": "git-alias-semantic-unverified",
            "pattern": "(?!)",
            "severity": "high",
            "description": GIT_ALIAS_REASON,
            "explanation": GIT_ALIAS_EXPLANATION,
        },
        {
            "name": "branch-dynamic-token",
            "pattern": "(?!)",
            "severity": "high",
            "description": BRANCH_DYNAMIC_REASON,
        },
    ]
    if existing >= {"git-alias-semantic-unverified", "branch-dynamic-token"}:
        return items
    # Source uses struct literals, not the macro. Prepend so order matches 0.11.0.
    return semantic + items


def assert_names(kind: str, got: list[str], expected: list[str], drift: list[str]) -> None:
    if got != expected:
        drift.append(f"{kind}: source {got} vs checklist {expected}")
        missing = [n for n in expected if n not in got]
        extra = [n for n in got if n not in expected]
        if missing:
            drift.append(f"{kind} missing vs checklist: {missing}")
        if extra:
            drift.append(f"{kind} extra vs checklist: {extra}")


def write_pack(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    blob = json.dumps(payload, indent=2, ensure_ascii=False) + "\n"
    if _FORBIDDEN.search(blob):
        raise SystemExit(f"refusing to write {path}: forbidden token")
    path.write_text(blob)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", required=True)
    parser.add_argument(
        "--dest",
        default=str(Path(__file__).resolve().parents[2] / "Sources/RVPacks/Resources/packs"),
    )
    args = parser.parse_args()
    root = Path(args.source_root)
    git_rs = (root / "src/packs/core/git.rs").read_text()
    fs_rs = (root / "src/packs/core/filesystem.rs").read_text()

    git_safe = extract_macros(git_rs, "safe_pattern")
    git_dest = inject_git_semantic(extract_macros(git_rs, "destructive_pattern"))
    fs_safe = extract_macros(fs_rs, "safe_pattern")
    fs_dest = extract_macros(fs_rs, "destructive_pattern")

    drift: list[str] = []
    assert_names("core.git safe", [p["name"] for p in git_safe], GIT_SAFE_NAMES, drift)
    assert_names(
        "core.git destructive", [p["name"] for p in git_dest], GIT_DESTRUCTIVE_NAMES, drift
    )
    assert_names("core.filesystem safe", [p["name"] for p in fs_safe], FS_SAFE_NAMES, drift)
    assert_names(
        "core.filesystem destructive",
        [p["name"] for p in fs_dest],
        FS_DESTRUCTIVE_NAMES,
        drift,
    )

    dest = Path(args.dest)
    write_pack(
        dest / "core.git.json",
        {
            "schema_version": 1,
            "id": "core.git",
            "name": "Core Git",
            "version": PINNED_VERSION,
            "description": (
                "Protects against destructive git commands that can lose uncommitted "
                "work, rewrite history, or destroy stashes"
            ),
            "enabled_by_default": True,
            "keywords": ["git"],
            "safe_patterns": git_safe,
            "destructive_patterns": git_dest,
        },
    )
    write_pack(
        dest / "core.filesystem.json",
        {
            "schema_version": 1,
            "id": "core.filesystem",
            "name": "Core Filesystem",
            "version": PINNED_VERSION,
            "description": (
                "Protects against recursive rm commands and equivalent filesystem "
                "destruction outside literal temp subdirectories"
            ),
            "enabled_by_default": True,
            "keywords": [
                "rm",
                "find",
                "unlink",
                "truncate",
                "shred",
                "tar",
                "dd",
                "mv",
                "cp",
                "ln",
                "rsync",
                ">/",
                "> /",
                ">~",
                "> ~",
                ">$",
                "> $",
                '>"',
                '> "',
                ">'",
                "> '",
                "&>",
                ">&",
                ">|",
                "1>",
                "2>",
                ">%",
                "> %",
                ">!",
                "> !",
                ">^",
                "> ^",
            ],
            "safe_patterns": fs_safe,
            "destructive_patterns": fs_dest,
        },
    )

    print(f"wrote {dest / 'core.git.json'} ({len(git_safe)} safe, {len(git_dest)} destructive)")
    print(
        f"wrote {dest / 'core.filesystem.json'} ({len(fs_safe)} safe, {len(fs_dest)} destructive)"
    )
    if drift:
        print("NAME DRIFT (source wins):")
        for line in drift:
            print(f"  {line}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
