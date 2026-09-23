#!/usr/bin/env python3
"""Fail if RVIsolationTests depends on anything but RVIsolation and the two C helpers.

RVEngine stays forbidden. rv-isolation-exec (Linux) and rv-pty-claim (Darwin)
are C trampolines, the same class as each other, not extra Swift modules.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "Package.swift"
ALLOWED = {"RVIsolation", "rv-isolation-exec", "rv-pty-claim"}


def isolation_test_dependency_blocks(text: str) -> list[str]:
    return re.findall(
        r"let isolationTestDependencies: \[Target\.Dependency\] = \[(.*?)\]",
        text,
        flags=re.S,
    )


def isolation_test_dependencies(blocks: list[str]) -> list[str]:
    deps: list[str] = []
    for raw in blocks:
        deps.extend(re.findall(r'"([^"]+)"', raw))
    return deps


def isolation_test_target_expression(text: str) -> str | None:
    """The dependency expression on the RVIsolationTests target, not the array."""
    match = re.search(
        r'\.testTarget\(\s*name:\s*"RVIsolationTests"\s*,\s*dependencies:\s*(.*?)\)',
        text,
        flags=re.S,
    )
    if match is None:
        return None
    return " ".join(match.group(1).split())


def main() -> int:
    if PACKAGE.is_file() is False:
        print("check-swift-test-preflight: Package.swift missing", file=sys.stderr)
        return 1
    text = PACKAGE.read_text()
    blocks = isolation_test_dependency_blocks(text)
    if len(blocks) == 0:
        print(
            "check-swift-test-preflight: isolationTestDependencies assignment not found",
            file=sys.stderr,
        )
        return 1
    deps = isolation_test_dependencies(blocks)
    if len(deps) == 0:
        print(
            "check-swift-test-preflight: isolationTestDependencies parsed no modules",
            file=sys.stderr,
        )
        return 1
    extra = [dep for dep in deps if dep not in ALLOWED]
    unique = list(dict.fromkeys(deps))
    if extra:
        print(
            f"check-swift-test-preflight: RVIsolationTests extra modules: {extra}",
            file=sys.stderr,
        )
        return 1
    if len(unique) > 3:
        print(
            "check-swift-test-preflight: RVIsolationTests has "
            f"{len(unique)} modules: {unique}",
            file=sys.stderr,
        )
        return 1
    expression = isolation_test_target_expression(text)
    if expression != "isolationTestDependencies":
        print(
            "check-swift-test-preflight: RVIsolationTests dependencies must be "
            f"isolationTestDependencies, found {expression!r}",
            file=sys.stderr,
        )
        return 1
    print("check-swift-test-preflight: RVIsolationTests deps ok", unique)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
