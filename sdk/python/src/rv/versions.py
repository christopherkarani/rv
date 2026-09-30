"""IPC version parsing, skew checks, and minimum floors.

Ports ``Sources/RVIPC/ProtocolVersion.swift`` and ``EvaluationRoute.path``
fail-closed. Policy: ``sdk/VERSIONING.md``.
"""

from __future__ import annotations

from .errors import MajorVersionSkew, RuntimeTooOld

PROTOCOL_NAME = "rv.ipc.v1"
SDK_IPC_SEMVER = "1.0.0"
MIN_PRODUCT = "0.1.5"
MIN_IPC_MAJOR = 1
_INT32_MAX = 2_147_483_647


def major_of(semver: str) -> int | None:
    """Major version of a ``"<head>.<rest>"`` semver, else ``None``.

    Grammar mirrors ``ProtocolVersion.major`` (and ``rv_semver_major`` in C):
    the head before the first ``.`` must be 1-15 ASCII digits and fit
    ``INT32_MAX``. Misses (empty head, non-digit bytes, 16+ chars, overflow)
    return ``None``; callers that must fail closed treat ``None`` as
    incompatible.
    """
    head = semver.split(".", 1)[0]
    if not head or len(head) > 15 or not head.isascii() or not head.isdigit():
        return None
    value = int(head)
    if value > _INT32_MAX:
        return None
    return value


def is_major_skew(client_semver: str, service_semver: str) -> bool:
    """True only when both semvers parse and their majors differ.

    Unparseable input is not skew (returns ``False``); fail-closed callers
    check ``major_of`` for ``None`` separately.
    """
    client = major_of(client_semver)
    service = major_of(service_semver)
    if client is None or service is None:
        return False
    return client != service


def check_compatible(client_semver: str, service_semver: str | None) -> None:
    """Fail-closed compatibility gate (mirror of ``EvaluationRoute.path``).

    Missing, empty, or unparseable advertised service semver cannot prove
    compatibility. Raises ``MajorVersionSkew``; returns ``None`` on provable
    major equality.
    """
    service_major = major_of(service_semver) if service_semver else None
    client_major = major_of(client_semver)
    if service_major is None or client_major is None or client_major != service_major:
        raise MajorVersionSkew(
            f"rv IPC major skew: client {client_semver!r} vs service {service_semver!r}; "
            "upgrade the older side",
            client_semver=client_semver,
            service_semver=service_semver,
        )


def product_at_least(found: str, minimum: str = MIN_PRODUCT) -> bool:
    """True when product version ``found`` is at least ``minimum``.

    Compares the leading numeric ``major.minor.patch`` triple; unparseable
    input fails closed (``False``).
    """
    parsed_found = _product_triple(found)
    parsed_min = _product_triple(minimum)
    if parsed_found is None or parsed_min is None:
        return False
    return parsed_found >= parsed_min


def check_product_floor(found: str, minimum: str = MIN_PRODUCT) -> None:
    """Raise ``RuntimeTooOld`` unless ``found`` meets the product floor."""
    if not product_at_least(found, minimum):
        raise RuntimeTooOld(
            f"RV runtime {found!r} is below the minimum {minimum!r}; upgrade RV",
            minimum=minimum,
            found=found,
        )


def _product_triple(version: str) -> tuple[int, int, int] | None:
    parts = version.strip().split(".")
    if len(parts) < 3:
        return None
    triple: list[int] = []
    for part in parts[:3]:
        run = ""
        for ch in part:
            if ch.isascii() and ch.isdigit():
                run += ch
            else:
                break
        if not run:
            return None
        triple.append(int(run))
    return (triple[0], triple[1], triple[2])
