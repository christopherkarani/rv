"""Wire envelope codec: Hello/HelloAck, IPCRequest/IPCResponse, IPCError.

Mirrors ``Sources/RVIPC/IPCEnvelope.swift`` field-for-field. Method params and
result payloads pass through as raw dicts; typed interpretation lives in
``models`` (curated) while ``raw`` exposes these dicts verbatim. Unknown JSON
object keys are ignored everywhere; closed enums and combo rules fail closed.
See ``sdk/WIRE.md`` §§3-5, §7.
"""

from __future__ import annotations

import json
import uuid
from dataclasses import dataclass
from typing import Any

from .errors import (
    DecodeError,
    IPCErrorValue,
    UnexpectedResult,
    raise_for_ipc_error,
)
from .versions import PROTOCOL_NAME, SDK_IPC_SEMVER

METHODS = (
    "evaluate",
    "hookEvaluate",
    "explain",
    "classify",
    "listPacks",
    "setPackEnabled",
    "doctorSnapshot",
    "pendingList",
    "pendingWatch",
    "pendingResolve",
    "rulePreview",
    "ruleSave",
)

SKEW_PROTOCOL = "protocol"
SKEW_MAJOR_VERSION = "major version"
SKEW_CORE_PACKS = "core packs unavailable"
SKEW_HANDSHAKE_REQUIRED = "handshake required"

_ENGINE_SENTENCES = {
    "hook evaluate failed": "hookEvaluateFailed",
    "pack enable failed": "packEnableFailed",
    "rule pin requires a matching view": "rulePinRequiresMatchingView",
    "pending allowOnce is not unlockable": "pendingAllowOnceNotUnlockable",
    "pending coordinator unavailable": "pendingCoordinatorUnavailable",
}


def dumps_canonical(value: Any) -> bytes:
    """Encode request JSON: sorted keys, compact separators, UTF-8.

    Requests need semantic — not byte — equality with Swift output, so this
    does not replicate Foundation escaping quirks.
    """
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode(
        "utf-8"
    )


def loads_object(data: bytes) -> dict[str, Any]:
    """Decode bytes as a JSON object, else ``DecodeError``."""
    try:
        value = json.loads(data)
    except (ValueError, UnicodeDecodeError) as exc:
        raise DecodeError(f"body is not JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise DecodeError("body is not a JSON object")
    return value


def format_uuid(value: uuid.UUID) -> str:
    """Uppercase form, matching Swift's encoder for byte parity."""
    return str(value).upper()


def parse_uuid(raw: Any) -> uuid.UUID:
    """Parse any-case UUID string, else ``DecodeError``."""
    if not isinstance(raw, str):
        raise DecodeError("id is not a string")
    try:
        return uuid.UUID(raw)
    except ValueError as exc:
        raise DecodeError(f"invalid UUID: {raw!r}") from exc


@dataclass(frozen=True)
class Hello:
    protocol: str = PROTOCOL_NAME
    client_semver: str = SDK_IPC_SEMVER

    def to_dict(self) -> dict[str, Any]:
        return {"protocol": self.protocol, "clientSemver": self.client_semver}

    def encode(self) -> bytes:
        return dumps_canonical(self.to_dict())


@dataclass(frozen=True)
class HelloAck:
    protocol: str
    service_semver: str
    ok: bool
    skew_reason: str | None = None

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> HelloAck:
        protocol = value.get("protocol")
        service_semver = value.get("serviceSemver")
        ok = value.get("ok")
        if not isinstance(protocol, str):
            raise DecodeError("HelloAck.protocol is not a string")
        if not isinstance(service_semver, str):
            raise DecodeError("HelloAck.serviceSemver is not a string")
        if not isinstance(ok, bool):
            raise DecodeError("HelloAck.ok is not a bool")
        reason = value.get("skewReason")
        if ok and reason is not None:
            raise DecodeError("ok handshake must omit skewReason")
        if not ok and not isinstance(reason, str):
            raise DecodeError("skewed handshake requires a skewReason string")
        return cls(
            protocol=protocol,
            service_semver=service_semver,
            ok=ok,
            skew_reason=reason if isinstance(reason, str) else None,
        )

    @classmethod
    def decode(cls, data: bytes) -> HelloAck:
        return cls.from_dict(loads_object(data))


@dataclass(frozen=True)
class WireRequest:
    """One ``IPCRequest``: fresh id, protocol, single-key method object."""

    id: uuid.UUID
    method: str
    params: dict[str, Any]

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": format_uuid(self.id),
            "protocol": PROTOCOL_NAME,
            "method": {self.method: self.params},
        }

    def encode(self) -> bytes:
        return dumps_canonical(self.to_dict())

    @classmethod
    def decode(cls, data: bytes) -> WireRequest:
        value = loads_object(data)
        return cls(
            id=parse_uuid(value.get("id")),
            method=_single_key(value.get("method"), "method"),
            params=_method_value(value.get("method")),
        )


@dataclass(frozen=True)
class WireResult:
    """One decoded ``result`` object: either ``(method, payload)`` or an error."""

    method: str | None
    payload: dict[str, Any] | None
    error: IPCErrorValue | None

    @property
    def is_error(self) -> bool:
        return self.error is not None


def decode_ipc_error(value: Any) -> IPCErrorValue:
    """Decode an ``IPCError`` object in Swift's normative key order
    (``IPCEnvelope.init(from:)``). Unit cases match on key *presence*, exactly
    like Swift's ``container.contains``; valued cases require the right type.
    """
    if not isinstance(value, dict):
        raise DecodeError("IPCError is not an object")
    if "unknownMethod" in value:
        return IPCErrorValue("unknownMethod")
    if "decodeFailed" in value:
        return IPCErrorValue("decodeFailed")
    if "protocolSkew" in value:
        reason = value["protocolSkew"]
        if not isinstance(reason, str):
            raise DecodeError("protocolSkew reason is not a string")
        return IPCErrorValue("protocolSkew", reason)
    if "engine" in value:
        message = value["engine"]
        if not isinstance(message, str):
            raise DecodeError("engine message is not a string")
        return IPCErrorValue(_ENGINE_SENTENCES.get(message, "engine"), message)
    if "packNotFound" in value:
        pack = value["packNotFound"]
        if not isinstance(pack, str):
            raise DecodeError("packNotFound id is not a string")
        return IPCErrorValue("packNotFound", pack)
    for key in (
        "allowOnceNotFound",
        "allowOnceAlreadyConsumed",
        "allowOnceExpired",
        "pendingNotFound",
        "pendingAlreadyTerminal",
        "pendingIdentityMismatch",
        "pendingFingerprintMismatch",
        "ruleDraftMismatch",
        "ruleHardStop",
    ):
        if key in value:
            return IPCErrorValue(key)
    raise DecodeError(f"unknown IPCError shape: {sorted(value)!r}")


def decode_response(data: bytes, *, request_id: uuid.UUID, method: str) -> dict[str, Any]:
    """Decode an ``IPCResponse``: verify id/protocol echo, surface errors as
    typed exceptions, and return the result payload dict for ``method``.

    Raises ``UnexpectedResult`` on echo mismatch or wrong reply variant, and
    the mapped ``RvError`` subclass on ``{"error": ...}`` results.
    """
    value = loads_object(data)
    response_id = parse_uuid(value.get("id"))
    if response_id != request_id:
        raise UnexpectedResult("response id does not echo the request id")
    if value.get("protocol") != PROTOCOL_NAME:
        raise UnexpectedResult("response protocol is not rv.ipc.v1")
    result = value.get("result")
    if not isinstance(result, dict):
        raise DecodeError("response result is not an object")
    if "error" in result:
        raise_for_ipc_error(decode_ipc_error(result["error"]))
    if method not in result or not isinstance(result[method], dict):
        raise UnexpectedResult(f"response is not a {method} reply")
    return result[method]


def decode_result_object(value: Any) -> WireResult:
    """Decode a bare ``result`` object without echo checks (tests/tools)."""
    if not isinstance(value, dict):
        raise DecodeError("result is not an object")
    if "error" in value:
        return WireResult(method=None, payload=None, error=decode_ipc_error(value["error"]))
    for name in METHODS:
        if name in value and isinstance(value[name], dict):
            return WireResult(method=name, payload=value[name], error=None)
    raise DecodeError(f"unknown IPCResult shape: {sorted(value)!r}")


def _single_key(value: Any, what: str) -> str:
    if not isinstance(value, dict) or len(value) != 1:
        raise DecodeError(f"{what} is not a single-key object")
    (key,) = value.keys()
    return key


def _method_value(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or len(value) != 1:
        raise DecodeError("method is not a single-key object")
    (params,) = value.values()
    if not isinstance(params, dict):
        raise DecodeError("method params are not an object")
    return params
