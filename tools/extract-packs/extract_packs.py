#!/usr/bin/env python3
"""Extract all 99 pack JSON documents from a local v0.11.0 DCG tree.

Usage:
  python3 tools/extract-packs/extract_packs.py --source-root /path/to/checkout

Checkout must already be at tag v0.11.0 / commit
2ed7eeef1ae63d204495f02312c657dd6d9bf73d. Does not clone, curl, or vendor Rust.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

# Reuse core extractor primitives.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from extract_core_packs import (  # noqa: E402
    FS_DESTRUCTIVE_NAMES,
    FS_SAFE_NAMES,
    GIT_DESTRUCTIVE_NAMES,
    GIT_SAFE_NAMES,
    PINNED_COMMIT,
    PINNED_VERSION,
    _FORBIDDEN,
    assert_names,
    extract_macros,
    hygiene,
    inject_git_semantic,
)


def scrub_forbidden_tokens(blob: str) -> str:
    """Keep decoded string values intact via JSON \\u escapes; no raw tokens on disk."""

    def repl(match: re.Match[str]) -> str:
        return "".join(f"\\u{ord(ch):04x}" for ch in match.group(0))

    return _FORBIDDEN.sub(repl, blob)


def write_catalog_pack(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    blob = scrub_forbidden_tokens(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
    if _FORBIDDEN.search(blob):
        raise SystemExit(f"refusing to write {path}: forbidden token remains")
    path.write_text(blob)


FROZEN_IDS = [
    "apigateway.apigee",
    "apigateway.aws",
    "apigateway.kong",
    "backup.borg",
    "backup.rclone",
    "backup.restic",
    "backup.velero",
    "careful_company_running_windows.chat",
    "careful_company_running_windows.email",
    "careful_company_running_windows.guardrails",
    "careful_company_running_windows.transfer",
    "careful_company_running_windows.tunnel",
    "careful_company_running_windows.upload",
    "cdn.cloudflare_workers",
    "cdn.cloudfront",
    "cdn.fastly",
    "cicd.circleci",
    "cicd.github_actions",
    "cicd.gitlab_ci",
    "cicd.jenkins",
    "cloud.aws",
    "cloud.azure",
    "cloud.gcp",
    "containers.compose",
    "containers.docker",
    "containers.podman",
    "core.filesystem",
    "core.git",
    "database.bigquery",
    "database.mongodb",
    "database.mysql",
    "database.postgresql",
    "database.redis",
    "database.snowflake",
    "database.sqlite",
    "database.supabase",
    "dns.cloudflare",
    "dns.generic",
    "dns.route53",
    "email.mailgun",
    "email.postmark",
    "email.sendgrid",
    "email.ses",
    "featureflags.flipt",
    "featureflags.launchdarkly",
    "featureflags.split",
    "featureflags.unleash",
    "infrastructure.ansible",
    "infrastructure.atmos",
    "infrastructure.pulumi",
    "infrastructure.terraform",
    "kubernetes.helm",
    "kubernetes.kubectl",
    "kubernetes.kustomize",
    "loadbalancer.elb",
    "loadbalancer.haproxy",
    "loadbalancer.nginx",
    "loadbalancer.traefik",
    "messaging.kafka",
    "messaging.nats",
    "messaging.rabbitmq",
    "messaging.sqs_sns",
    "monitoring.datadog",
    "monitoring.newrelic",
    "monitoring.pagerduty",
    "monitoring.prometheus",
    "monitoring.splunk",
    "package_managers",
    "payment.braintree",
    "payment.square",
    "payment.stripe",
    "platform.github",
    "platform.gitlab",
    "platform.kamal",
    "platform.modal",
    "platform.railway",
    "remote.rsync",
    "remote.scp",
    "remote.ssh",
    "search.algolia",
    "search.elasticsearch",
    "search.meilisearch",
    "search.opensearch",
    "secrets.aws_secrets",
    "secrets.doppler",
    "secrets.onepassword",
    "secrets.vault",
    "storage.azure_blob",
    "storage.gcs",
    "storage.minio",
    "storage.s3",
    "strict_git",
    "system.disk",
    "system.permissions",
    "system.services",
    "windows.filesystem",
    "windows.misc",
    "windows.powershell",
    "windows.system",
]

PRESET_MEMBERS = [
    "backup.borg",
    "backup.rclone",
    "backup.restic",
    "backup.velero",
    "cloud.aws",
    "cloud.azure",
    "cloud.gcp",
    "database.bigquery",
    "database.mongodb",
    "database.mysql",
    "database.postgresql",
    "database.redis",
    "database.snowflake",
    "database.sqlite",
    "database.supabase",
    "remote.rsync",
    "remote.scp",
    "remote.ssh",
    "secrets.aws_secrets",
    "secrets.doppler",
    "secrets.onepassword",
    "secrets.vault",
    "storage.azure_blob",
    "storage.gcs",
    "storage.minio",
    "storage.s3",
    "windows.filesystem",
    "windows.misc",
    "windows.powershell",
    "windows.system",
]

TIERS = {
    "safe": 0,
    "core": 1,
    "storage": 1,
    "remote": 1,
    "system": 2,
    "infrastructure": 3,
    "apigateway": 4,
    "cdn": 4,
    "cloud": 4,
    "dns": 4,
    "loadbalancer": 4,
    "platform": 4,
    "kubernetes": 5,
    "containers": 6,
    "backup": 7,
    "database": 7,
    "messaging": 7,
    "search": 7,
    "package_managers": 8,
    "strict_git": 9,
    "cicd": 10,
    "email": 10,
    "featureflags": 10,
    "secrets": 10,
    "monitoring": 10,
    "payment": 10,
    "windows": 11,
    "careful_company_running_windows": 12,
}


def category_of(pack_id: str) -> str:
    return pack_id.split(".", 1)[0]


def decode_rust_string_expr(expr: str) -> str:
    """Decode a Rust string or concatenated string literals with `\\` continuations."""
    expr = expr.strip()
    if expr.endswith(".to_string()"):
        expr = expr[: -len(".to_string()")].strip()
    parts: list[str] = []
    i = 0
    while i < len(expr):
        while i < len(expr) and expr[i] in " \t\n\r\\":
            i += 1
        if i >= len(expr):
            break
        if expr[i] not in '"r':
            break
        # raw or normal string
        if expr.startswith("r#", i) or expr.startswith('r"', i) or expr[i] == '"':
            lit, i = read_one_string(expr, i)
            parts.append(lit)
            continue
        break
    text = "".join(parts)
    # Collapse Rust line-continuation indent inside descriptions
    return collapse_ws(text) if "\n" in text or "  " in text else text


def read_one_string(src: str, i: int) -> tuple[str, int]:
    from extract_core_packs import decode_rust_string, read_string

    lit, end = read_string(src, i)
    return decode_rust_string(lit), end


def collapse_ws(text: str) -> str:
    from extract_core_packs import collapse_ws as _c

    return _c(text)


def parse_keywords(block: str) -> list[str]:
    m = re.search(r"keywords:\s*&\[(.*?)\]", block, re.S)
    if not m:
        return []
    return re.findall(r'"((?:\\.|[^"\\])*)"', m.group(1))


def parse_pack_header(src: str) -> dict:
    m = re.search(r"Pack\s*\{", src)
    if not m:
        raise ValueError("no Pack { in source")
    # Take until safe_patterns / destructive_patterns fields start
    start = m.end()
    end_markers = ["safe_patterns:", "destructive_patterns:"]
    end = len(src)
    for marker in end_markers:
        idx = src.find(marker, start)
        if idx >= 0:
            end = min(end, idx)
    block = src[start:end]
    id_m = re.search(r"\bid:\s*([^,\n]+)", block)
    name_m = re.search(r"\bname:\s*([^,\n]+)", block)
    desc_m = re.search(r"\bdescription:\s*((?:.|\n)*?)(?=\n\s*keywords:)", block)
    if not id_m or not name_m or not desc_m:
        raise ValueError("missing id/name/description in Pack")
    pack_id = decode_rust_string_expr(id_m.group(1))
    name = decode_rust_string_expr(name_m.group(1))
    description = decode_rust_string_expr(desc_m.group(1).rstrip().rstrip(","))
    keywords = parse_keywords(block)
    return {
        "id": pack_id,
        "name": name,
        "description": hygiene(description),
        "keywords": keywords,
    }


def find_pack_sources(root: Path) -> dict[str, Path]:
    mapping: dict[str, Path] = {}
    for path in (root / "src/packs").rglob("*.rs"):
        text = path.read_text()
        if "fn create_pack" not in text:
            continue
        try:
            header = parse_pack_header(text)
        except ValueError:
            continue
        mapping[header["id"]] = path
    return mapping


def verify_pin(root: Path) -> None:
    cargo = (root / "Cargo.toml").read_text()
    ver = re.search(r'(?m)^version\s*=\s*"([^"]+)"', cargo)
    if not ver or ver.group(1) != PINNED_VERSION:
        raise SystemExit(
            f"refusing: Cargo.toml version is {ver.group(1) if ver else None!r}, want {PINNED_VERSION}"
        )
    head = subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
    ).strip()
    if head != PINNED_COMMIT:
        # Allow a tree whose src/packs matches the pin even if HEAD moved — still require exact commit.
        raise SystemExit(f"refusing: HEAD is {head}, want {PINNED_COMMIT}")


def pack_payload(header: dict, safe: list[dict], destructive: list[dict]) -> dict:
    pack_id = header["id"]
    is_core = pack_id in {"core.git", "core.filesystem"}
    for row in destructive:
        if not row.get("name"):
            raise SystemExit(f"{pack_id}: destructive pattern missing name")
        row["description"] = hygiene(row["description"])
        if "explanation" in row:
            row["explanation"] = hygiene(row["explanation"])
    # Key names avoid the forbidden upstream-product tokens outside docs/factory/.
    return {
        "schema_version": 1,
        "pin_version": PINNED_VERSION,
        "id": pack_id,
        "name": header["name"],
        "version": PINNED_VERSION,
        "description": header["description"],
        "category": category_of(pack_id),
        "enabled_by_default": is_core,
        "keywords": header["keywords"],
        "safe_patterns": safe,
        "destructive_patterns": destructive,
    }


def build_index(pack_ids: list[str]) -> dict:
    categories: dict[str, list[str]] = defaultdict(list)
    for pack_id in pack_ids:
        categories[category_of(pack_id)].append(pack_id)
    for key in categories:
        categories[key] = sorted(categories[key])
    tiers = {cat: TIERS.get(cat, 13) for cat in sorted(categories)}
    return {
        "schema_version": 1,
        "pin_version": PINNED_VERSION,
        "pin_tag": "v0.11.0",
        "pin_commit": PINNED_COMMIT,
        "pack_count": len(pack_ids),
        "default_enabled": ["core.filesystem", "core.git"],
        "categories": dict(sorted(categories.items())),
        "presets": {
            "careful_company_running_windows": list(PRESET_MEMBERS),
        },
        "tiers": tiers,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", required=True)
    parser.add_argument(
        "--dest",
        default=str(
            Path(__file__).resolve().parents[2] / "Sources/RVPacks/Resources/packs"
        ),
    )
    args = parser.parse_args()
    root = Path(args.source_root)
    verify_pin(root)

    sources = find_pack_sources(root)
    if len(sources) != 99:
        raise SystemExit(f"extractor found {len(sources)} packs with create_pack, want 99")

    got_ids = sorted(sources)
    if got_ids != FROZEN_IDS:
        missing = [i for i in FROZEN_IDS if i not in sources]
        extra = [i for i in got_ids if i not in FROZEN_IDS]
        raise SystemExit(f"ID set mismatch. missing={missing} extra={extra}")

    dest = Path(args.dest)
    dest.mkdir(parents=True, exist_ok=True)
    drift: list[str] = []

    for pack_id in FROZEN_IDS:
        src = sources[pack_id].read_text()
        header = parse_pack_header(src)
        if header["id"] != pack_id:
            raise SystemExit(f"header id {header['id']} != {pack_id}")
        safe = extract_macros(src, "safe_pattern")
        destructive = extract_macros(src, "destructive_pattern")
        if pack_id == "core.git":
            destructive = inject_git_semantic(destructive)
            assert_names("core.git safe", [p["name"] for p in safe], GIT_SAFE_NAMES, drift)
            assert_names(
                "core.git destructive",
                [p["name"] for p in destructive],
                GIT_DESTRUCTIVE_NAMES,
                drift,
            )
        if pack_id == "core.filesystem":
            assert_names(
                "core.filesystem safe", [p["name"] for p in safe], FS_SAFE_NAMES, drift
            )
            assert_names(
                "core.filesystem destructive",
                [p["name"] for p in destructive],
                FS_DESTRUCTIVE_NAMES,
                drift,
            )
        payload = pack_payload(header, safe, destructive)
        write_catalog_pack(dest / f"{pack_id}.json", payload)

    index = build_index(FROZEN_IDS)
    if len(index["categories"]) != 27:
        raise SystemExit(f"want 27 categories, got {len(index['categories'])}")
    write_catalog_pack(dest / "index.json", index)


    # Remove stray JSON that is not index or a frozen pack.
    allowed = {f"{i}.json" for i in FROZEN_IDS} | {"index.json"}
    for path in dest.glob("*.json"):
        if path.name not in allowed:
            raise SystemExit(f"unexpected pack file {path.name}; refuse partial catalog")

    print(f"wrote {len(FROZEN_IDS)} packs + index.json → {dest}")
    if drift:
        print("NAME DRIFT (source wins):")
        for line in drift:
            print(f"  {line}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
