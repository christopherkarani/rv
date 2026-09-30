"""Untyped forward-compat hatch: raw wire dicts, no curated models."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

from . import protocol

if TYPE_CHECKING:
    from .client import Client


class RawClient:
    """Verbatim ``rv.ipc.v1`` access, reached via ``Client.raw``.

    Connection integrity still applies (id/protocol echo, ``IPCError`` mapped
    to typed exceptions, ``serviceSemver`` major gate when a reply carries
    one), but payloads return as plain dicts with no semantic validation: no
    ``via`` check, no outcome algebra, no curated models. New methods and
    fields are visible here without an SDK update.
    """

    def __init__(self, client: Client) -> None:
        self._client = client

    def call(
        self,
        method: str,
        params: dict[str, Any] | None = None,
        timeout: float | None = None,
    ) -> dict[str, Any]:
        """Call ``method`` with raw ``params``; return the raw result payload."""
        if method not in protocol.METHODS:
            raise ValueError(f"unknown rv.ipc.v1 method: {method!r}")
        if params is not None and not isinstance(params, dict):
            raise ValueError("params must be a dict")
        return self._client._call(method, dict(params or {}), timeout)
