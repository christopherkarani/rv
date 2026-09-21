#!/usr/bin/env python3
"""Fail if RVIsolationTests lists a third Swift module (RVEngine is forbidden)."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "Package.swift"
ALLOWED = {"RVIsolation", "rv-isolation-exec"}


def isolation_test_dependencies(text: str) -> list[str]:
    matches = re.findall(
        r"let isolationTestDependencies: \[Target\.Dependency\] = \[(.*?)\]",
        text,
        flags=re.S,
    )
    deps: list[str] = []
    for raw in matches:
        deps.extend(re.findall(r'"([^"]+)"', raw))
    return deps


def main() -> int:
    if PACKAGE.is_file() is False:
        print("check-swift-test-preflight: Package.swift missing", file=sys.stderr)
        return 1
    text = PACKAGE.read_text()
    deps = isolation_test_dependencies(text)
    extra = [dep for dep in deps if dep not in ALLOWED]
    unique = list(dict.fromkeys(deps))
    if extra:
        print(
            f"check-swift-test-preflight: RVIsolationTests extra modules: {extra}",
            file=sys.stderr,
        )
        return 1
    if len(unique) > 2:
        print(
            "check-swift-test-preflight: RVIsolationTests has "
            f"{len(unique)} Swift modules: {unique}",
            file=sys.stderr,
        )
        return 1
    print("check-swift-test-preflight: RVIsolationTests deps ok", unique)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
