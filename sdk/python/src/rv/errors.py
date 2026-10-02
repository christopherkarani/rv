"""Exception hierarchy for the RV SDK.

Mirrors ``IPCError`` (``Sources/RVIPC/IPCEnvelope.swift``) 1:1, plus
transport-local failures. No unstructured strings: every exception carries the
wire value that caused it. See ``sdk/WIRE.md`` §7.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, NoReturn


class RvError(Exception):
    """Base class for every error raised by this package."""


# ---------------------------------------------------------------------------
# Transport-local failures (never cross the wire as IPCError).
# ---------------------------------------------------------------------------


class TransportError(RvError):
    """The SDK could not talk to the service (connect, timeout, framing)."""


class ConnectionFailed(TransportError):
    """Connect refused, socket missing/unusable, EOF, or peer check failed."""


class Timeout(TransportError):
    """A connect or call budget expired. A timeout is never a verdict."""

    def __init__(self, message: str, *, timeout: float | None = None) -> None:
        super().__init__(message)
        self.timeout = timeout


class FrameError(TransportError):
    """Length-prefix framing violation. ``kind`` is one of the ``FrameCodec``
    cases: ``empty``, ``truncated``, ``oversized``, ``lengthMismatch``."""

    def __init__(self, message: str, *, kind: str) -> None:
        super().__init__(message)
        self.kind = kind


class DecodeError(TransportError):
    """Bytes on the wire are not the value the contract requires
    (``IPCError.decodeFailed`` equivalent plus local JSON mismatch)."""


class SocketPathTooLong(TransportError):
    """Resolved socket path does not fit ``sockaddr_un``."""

    def __init__(self, message: str, *, path: str) -> None:
        super().__init__(message)
        self.path = path


# ---------------------------------------------------------------------------
# Handshake / version failures.
# ---------------------------------------------------------------------------


class ProtocolError(RvError):
    """Handshake, skew, or response-identity failure. Never retried blindly."""


class HandshakeRequired(ProtocolError):
    """Method call before an accepted handshake (client bug: always Hello first)."""


class ProtocolSkew(ProtocolError):
    """Protocol-name mismatch (``protocol`` skew reason)."""

    def __init__(self, message: str, *, reason: str) -> None:
        super().__init__(message)
        self.reason = reason


class MajorVersionSkew(ProtocolError):
    """Client/service IPC majors differ, or a version is missing/unparseable.

    The SDK has no engine, so skew is a hard error, never an in-process
    fallback (``sdk/VERSIONING.md`` §4).
    """

    def __init__(
        self,
        message: str,
        *,
        client_semver: str | None = None,
        service_semver: str | None = None,
    ) -> None:
        super().__init__(message)
        self.client_semver = client_semver
        self.service_semver = service_semver


class CorePacksUnavailable(ProtocolError):
    """The service answered but its core packs are not ready."""


class UnknownMethod(ProtocolError):
    """The service decoded the frame but refuses the method key."""


class UnexpectedResult(ProtocolError):
    """id/protocol echo mismatch or wrong reply variant for the call."""


# ---------------------------------------------------------------------------
# Approval failures (fingerprint/identity binding enforced service-side).
# ---------------------------------------------------------------------------


class ApprovalError(RvError):
    """A pending-approval operation was refused."""


class PendingNotFound(ApprovalError):
    """No such approval id."""


class PendingAlreadyTerminal(ApprovalError):
    """Resolved, consumed, expired, canceled, or timed out: single-use spent."""


class PendingIdentityMismatch(ApprovalError):
    """Identity echo mismatch: caller bug or replay attempt. Never retried."""


class PendingFingerprintMismatch(ApprovalError):
    """Fingerprint echo mismatch: caller bug or replay attempt. Never retried."""


class AllowOnceNotUnlockable(ApprovalError):
    """No supporting command, host-native refusal, or grant-plant failure."""


class CoordinatorUnavailable(ApprovalError):
    """Missing store, lock, or encode failure on the service."""


class AllowOnceError(RvError):
    """A planted single-use grant is missing, spent, or expired."""


class AllowOnceNotFound(AllowOnceError):
    """No such grant."""


class AllowOnceAlreadyConsumed(AllowOnceError):
    """Grant already spent: exactly-once enforced."""


class AllowOnceExpired(AllowOnceError):
    """Grant expired before use."""


# ---------------------------------------------------------------------------
# Pack / rule / hook failures.
# ---------------------------------------------------------------------------


class PackError(RvError):
    """A pack operation was refused."""


class PackNotFound(PackError):
    """Unknown pack id (carries the id)."""

    def __init__(self, message: str, *, pack_id: str) -> None:
        super().__init__(message)
        self.pack_id = pack_id


class PackEnableFailed(PackError):
    """Pack mutation failed on the service (operator action required)."""


class RuleError(RvError):
    """A rule pin operation was refused."""


class RuleDraftMismatch(RuleError):
    """Draft does not byte-echo the preview: re-preview, do not retry."""


class RuleHardStop(RuleError):
    """Allow-side hard stop (secret/protected/shared-branch/discard/...)."""


class RulePinRequiresMatchingView(RuleError):
    """Preview needs the matching view the pin applies to."""


class HookEvaluateFailed(RvError):
    """The hook door failed (raw-path only in v1)."""


class EngineError(RvError):
    """Leftover unknown ``engine`` sentence, preserved opaquely."""

    def __init__(self, message: str) -> None:
        super().__init__(message)


# ---------------------------------------------------------------------------
# Runtime presence / floor failures.
# ---------------------------------------------------------------------------


class RuntimeNotFound(RvError):
    """No usable RV runtime: missing binary, socket, base dir, or platform."""

    def __init__(self, message: str, *, path: str | None = None, remediation: str = "") -> None:
        super().__init__(message)
        self.path = path
        self.remediation = remediation


class RuntimeTooOld(RvError):
    """Runtime below the SDK's minimum floor (upgrade, do not work around)."""

    def __init__(self, message: str, *, minimum: str = "", found: str = "") -> None:
        super().__init__(message)
        self.minimum = minimum
        self.found = found


# ---------------------------------------------------------------------------
# Wire IPCError value + mapping.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class IPCErrorValue:
    """One decoded ``IPCError``. ``kind`` is the wire key (or engine sentence
    classification); ``payload`` is the carried value for ``protocolSkew`` (reason
    string), ``packNotFound`` (pack id), and ``engine`` (message), else ``None``."""

    kind: str
    payload: Any = None


def raise_for_ipc_error(error: IPCErrorValue) -> NoReturn:
    """Raise the typed exception for a decoded wire ``IPCError``. Never returns."""
    kind, payload = error.kind, error.payload
    if kind == "unknownMethod":
        raise UnknownMethod("rvd refused the method key (version/capability issue)")
    if kind == "decodeFailed":
        raise DecodeError("rvd could not decode the request")
    if kind == "protocolSkew":
        raise _skew_error(str(payload))
    if kind == "hookEvaluateFailed":
        raise HookEvaluateFailed("rvd hook door failed")
    if kind == "packEnableFailed":
        raise PackEnableFailed("rvd could not enable/disable the pack")
    if kind == "rulePinRequiresMatchingView":
        raise RulePinRequiresMatchingView("rule pin requires a matching view")
    if kind == "pendingAllowOnceNotUnlockable":
        raise AllowOnceNotUnlockable("pending allowOnce is not unlockable")
    if kind == "pendingCoordinatorUnavailable":
        raise CoordinatorUnavailable("pending coordinator unavailable")
    if kind == "packNotFound":
        raise PackNotFound(f"unknown pack: {payload}", pack_id=str(payload))
    if kind == "allowOnceNotFound":
        raise AllowOnceNotFound("allow-once grant not found")
    if kind == "allowOnceAlreadyConsumed":
        raise AllowOnceAlreadyConsumed("allow-once grant already consumed")
    if kind == "allowOnceExpired":
        raise AllowOnceExpired("allow-once grant expired")
    if kind == "pendingNotFound":
        raise PendingNotFound("pending approval not found")
    if kind == "pendingAlreadyTerminal":
        raise PendingAlreadyTerminal("pending approval already terminal")
    if kind == "pendingIdentityMismatch":
        raise PendingIdentityMismatch("pending approval identity mismatch")
    if kind == "pendingFingerprintMismatch":
        raise PendingFingerprintMismatch("pending approval fingerprint mismatch")
    if kind == "ruleDraftMismatch":
        raise RuleDraftMismatch("rule draft does not match the preview")
    if kind == "ruleHardStop":
        raise RuleHardStop("rule pin blocked by hard stop")
    if kind == "engine":
        raise EngineError(f"rvd engine error: {payload}")
    raise DecodeError(f"unknown IPCError kind: {kind!r}")


def _skew_error(reason: str) -> ProtocolError:
    if reason == "handshake required":
        return HandshakeRequired("rvd requires a handshake before method calls")
    if reason == "protocol":
        return ProtocolSkew("rvd protocol mismatch", reason=reason)
    if reason == "major version":
        return MajorVersionSkew("rvd IPC major version skew")
    if reason == "core packs unavailable":
        return CorePacksUnavailable("rvd core packs unavailable")
    return ProtocolSkew(f"rvd reported unknown skew reason: {reason}", reason=reason)
