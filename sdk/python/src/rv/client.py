"""Curated sync client for ``rv.ipc.v1`` plus runtime helpers.

``Client`` connects over the production AF_UNIX socket, runs the Hello
handshake, and exposes one method per curated operation. It constructs typed
intents and relays opaque handles; every security decision stays in the Swift
service. Skew or an unreachable service is a hard typed error, never a local
verdict (``sdk/VERSIONING.md`` §4).
"""

from __future__ import annotations

import os
import shutil
import subprocess
import time
import uuid
from collections.abc import Iterable, Iterator
from dataclasses import dataclass
from typing import Any

from . import approvals, models, protocol, transports, versions
from .errors import (
    ConnectionFailed,
    CorePacksUnavailable,
    DecodeError,
    MajorVersionSkew,
    ProtocolSkew,
    RuntimeNotFound,
)
from .raw import RawClient
from .transports import DEFAULT_CALL_TIMEOUT, Transport, UnixSocketTransport

#: Curated methods. ``hookEvaluate`` is raw-only (host adapters stay Swift/C).
CURATED_METHODS = frozenset(
    {
        "evaluate",
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
    }
)
RAW_ONLY_METHODS = frozenset({"hookEvaluate"})


class Client:
    """Sync ``rv.ipc.v1`` client. Use as a context manager; not thread-safe
    (one connection per thread).
    """

    def __init__(
        self,
        socket_path: str | None = None,
        timeout: float = DEFAULT_CALL_TIMEOUT,
        transport: Transport | None = None,
    ) -> None:
        self._socket_path = socket_path
        self._timeout = timeout
        self._transport = transport or UnixSocketTransport(socket_path)
        self._raw: RawClient | None = None
        self._service_semver: str | None = None

    @property
    def raw(self) -> RawClient:
        """Untyped escape hatch (verbatim wire dicts)."""
        if self._raw is None:
            self._raw = RawClient(self)
        return self._raw

    @property
    def service_semver(self) -> str | None:
        """Negotiated service semver after connect, else ``None``."""
        return self._service_semver

    def connect(self) -> None:
        """Connect and run the Hello handshake (idempotent)."""
        self._transport.connect()
        ack_bytes = self._transport.round_trip(protocol.Hello().encode(), self._timeout)
        ack = protocol.HelloAck.decode(ack_bytes)
        if ack.protocol != versions.PROTOCOL_NAME:
            raise ProtocolSkew(
                f"service protocol is {ack.protocol!r}, want {versions.PROTOCOL_NAME!r}",
                reason=ack.protocol,
            )
        versions.check_compatible(versions.SDK_IPC_SEMVER, ack.service_semver)
        if not ack.ok:
            raise _skew_error(ack)
        product = _probe_product()
        if product is None:
            raise RuntimeNotFound(
                f"rvd not found on PATH; cannot verify minimum RV {versions.MIN_PRODUCT}",
                remediation="install RV: curl -fsSL https://rykanv.com/install | sh",
            )
        versions.check_product_floor(product)
        self._service_semver = ack.service_semver

    def close(self) -> None:
        self._transport.close()
        self._service_semver = None

    def __enter__(self) -> Client:
        self.connect()
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    # -- intent operations -------------------------------------------------

    def evaluate(
        self,
        command: str,
        cwd: str | os.PathLike[str] | None = None,
        packs: Iterable[str | models.PackID] | None = None,
        budget: int | None = None,
        timeout: float | None = None,
    ) -> models.Evaluation:
        """Evaluate a shell command against policy (allow/deny/indeterminate)."""
        payload = self._call(
            "evaluate", models.evaluate_params_wire(command, cwd, packs, budget), timeout
        )
        via = payload.get("via")
        if via != "xpc":
            raise DecodeError(f"evaluate reply has unexpected via: {via!r}")
        return models.Evaluation.from_wire(payload.get("result"))

    def explain(
        self,
        command: str,
        cwd: str | os.PathLike[str] | None = None,
        packs: Iterable[str | models.PackID] | None = None,
        budget: int | None = None,
        timeout: float | None = None,
    ) -> models.Explanation:
        """Explain a verdict: normalized view, suggestion, and stages."""
        payload = self._call(
            "explain", models.explain_params_wire(command, cwd, packs, budget), timeout
        )
        return models.Explanation.from_wire(payload)

    def classify(
        self,
        command: str,
        cwd: str | os.PathLike[str] | None = None,
        packs: Iterable[str | models.PackID] | None = None,
        budget: int | None = None,
        timeout: float | None = None,
    ) -> models.Classification:
        """Classify a command: decision, risk, reasons, suggestions."""
        payload = self._call(
            "classify", models.classify_params_wire(command, cwd, packs, budget), timeout
        )
        return models.Classification.from_wire(payload)

    def list_packs(self, timeout: float | None = None) -> models.PackList:
        """List the pack catalog with enablement."""
        return models.PackList.from_wire(self._call("listPacks", {}, timeout))

    def set_pack_enabled(
        self,
        pack_id: str | models.PackID,
        enabled: bool,
        timeout: float | None = None,
    ) -> models.Pack:
        """Enable/disable a pack. Operator-only: mutates service config."""
        payload = self._call(
            "setPackEnabled", models.set_pack_enabled_wire(pack_id, enabled), timeout
        )
        pack = payload.get("pack")
        if not isinstance(pack, dict):
            raise DecodeError("SetPackEnabledReply.pack is not an object")
        return models.Pack.from_wire(pack)

    def doctor(self, timeout: float | None = None) -> models.DoctorSnapshot:
        """Service health, versions, and check list."""
        return models.DoctorSnapshot.from_wire(self._call("doctorSnapshot", {}, timeout))

    def pending_list(self, timeout: float | None = None) -> models.PendingBatch:
        """Current approvals plus the watch generation."""
        return models.PendingBatch.from_wire(self._call("pendingList", {}, timeout))

    def watch_approvals(
        self,
        after_generation: int = 0,
        poll_interval: float = 1.0,
        timeout: float | None = None,
    ) -> Iterator[models.PendingBatch]:
        """Yield a batch per changed approval generation until ``timeout``."""
        yield from approvals.poll_batches(
            self,
            after_generation=after_generation,
            poll_interval=poll_interval,
            timeout=timeout,
        )

    def pending_resolve(
        self,
        item: models.PendingItem,
        allow: bool,
        timeout: float | None = None,
    ) -> models.ResolveResult:
        """Resolve one approval. Human-attended only: never auto-allow from an
        agent loop. ``allow=True`` records a single-use grant."""
        return approvals.resolve(self, item, allow, timeout)

    def rule_preview(
        self,
        approval_id: str,
        polarity: models.RulePolarity,
        timeout: float | None = None,
    ) -> models.RuleDraft:
        """Preview a pinned rule sentence and draft (never writes)."""
        payload = self._call(
            "rulePreview", models.rule_preview_wire(approval_id, polarity), timeout
        )
        return models.RuleDraft.from_wire(payload)

    def rule_save(
        self,
        approval_id: str,
        polarity: models.RulePolarity,
        draft: str,
        timeout: float | None = None,
    ) -> models.RuleSaveResult:
        """Persist a previewed rule draft. Operator-only: the draft must echo
        the preview."""
        payload = self._call(
            "ruleSave", models.rule_save_wire(approval_id, polarity, draft), timeout
        )
        return models.RuleSaveResult.from_wire(payload)

    # -- internals ----------------------------------------------------------

    def _pending_watch(self, after_generation: int) -> models.PendingBatch:
        payload = self._call("pendingWatch", models.pending_watch_wire(after_generation), None)
        return models.PendingBatch.from_wire(payload)

    def _call(self, method: str, params: dict[str, Any], timeout: float | None) -> dict[str, Any]:
        if self._service_semver is None:
            raise ConnectionFailed("client is not connected (use `with Client()` or .connect())")
        request = protocol.WireRequest(id=uuid.uuid4(), method=method, params=params)
        reply = self._transport.round_trip(
            request.encode(), self._timeout if timeout is None else timeout
        )
        payload = protocol.decode_response(reply, request_id=request.id, method=method)
        advertised = payload.get("serviceSemver")
        if advertised is not None:
            if not isinstance(advertised, str):
                raise DecodeError("reply serviceSemver is not a string")
            versions.check_compatible(versions.SDK_IPC_SEMVER, advertised)
        return payload


def _skew_error(ack: protocol.HelloAck) -> Exception:
    reason = ack.skew_reason or ""
    if reason == protocol.SKEW_MAJOR_VERSION:
        return MajorVersionSkew(
            f"rv IPC major skew: client {versions.SDK_IPC_SEMVER} vs service "
            f"{ack.service_semver}; upgrade the older side",
            client_semver=versions.SDK_IPC_SEMVER,
            service_semver=ack.service_semver,
        )
    if reason == protocol.SKEW_PROTOCOL:
        return ProtocolSkew("rv protocol mismatch", reason=reason)
    return CorePacksUnavailable("rv core packs unavailable")


def _find_rvd(explicit: str | None = None) -> str | None:
    """Locate the rvd binary: explicit path, then ``RV_RVD``, then ``PATH``."""
    if explicit:
        return explicit
    override = os.environ.get("RV_RVD")
    if override:
        return override
    return shutil.which("rvd")


def _probe_product(rvd: str | None = None) -> str | None:
    """Best-effort product version via ``rvd --version`` (informational; the
    probed binary may differ from the running daemon)."""
    binary = _find_rvd(rvd)
    if binary is None:
        return None
    try:
        completed = subprocess.run([binary, "--version"], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    if completed.returncode != 0:
        return None
    line = (completed.stdout or "").strip().splitlines()
    return line[0].strip() if line else None


@dataclass(frozen=True)
class RvRuntimeStatus:
    """``runtime_status()`` report. Works with no session."""

    ok: bool
    product: str | None
    protocol: str | None
    service: str | None
    transport: str
    path: str | None
    error: str | None = None


def runtime_status(socket_path: str | None = None) -> RvRuntimeStatus:
    """Probe the runtime: product version, transport reachability, versions,
    and minimum floors. Never raises: failures land in ``error`` with
    ``ok=False``."""
    product = _probe_product()
    try:
        path = transports.resolve_socket_path(socket_path)
    except Exception as exc:  # status must never raise
        return RvRuntimeStatus(
            ok=False,
            product=product,
            protocol=None,
            service=None,
            transport="unix-socket",
            path=None,
            error=str(exc),
        )
    try:
        with Client(socket_path=socket_path) as client:
            service = client.service_semver
    except Exception as exc:  # status must never raise
        return RvRuntimeStatus(
            ok=False,
            product=product,
            protocol=None,
            service=None,
            transport="unix-socket",
            path=path,
            error=str(exc),
        )
    return RvRuntimeStatus(
        ok=True,
        product=product,
        protocol=versions.PROTOCOL_NAME,
        service=service,
        transport="unix-socket",
        path=path,
    )


def ensure_runtime(socket_path: str | None = None, idle_exit_seconds: int | None = None) -> str:
    """Return a connectable socket path, explicitly spawning a supervised
    ``rvd`` when none answers. Never implicit: callers opt in (useful in
    containers without user units). Spawned daemons idle-exit on their own
    (default 300s; ``idle_exit_seconds`` overrides).

    Spawning targets the production path only: with an explicit override that
    does not answer, this raises instead of starting a daemon that would bind
    elsewhere.
    """
    path = transports.resolve_socket_path(socket_path)
    probe = UnixSocketTransport(path)
    try:
        probe.connect(timeout=0.2)
    except Exception:  # any failure means "try to start one"
        pass
    else:
        probe.close()
        return path
    if socket_path is not None:
        raise RuntimeNotFound(
            f"explicit rvd socket does not answer: {path} (spawn targets the production path only)",
            path=path,
        )
    binary = _find_rvd()
    if binary is None:
        raise RuntimeNotFound(
            "rvd not found on PATH; cannot start a runtime",
            remediation="install RV: curl -fsSL https://rykanv.com/install | sh",
        )
    argv = [binary]
    if idle_exit_seconds is not None:
        if idle_exit_seconds <= 0:
            raise ValueError("idle_exit_seconds must be positive")
        argv += ["--idle-exit-seconds", str(idle_exit_seconds)]
    try:
        # Fixed argv, no shell.
        proc = subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError as exc:
        raise RuntimeNotFound(f"cannot start rvd: {exc}") from exc
    deadline = time.monotonic() + 5
    last: Exception | None = None
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise RuntimeNotFound(f"rvd exited during startup (status {proc.returncode})")
        candidate = UnixSocketTransport(path)
        try:
            candidate.connect(timeout=0.2)
        except Exception as exc:  # retry until the deadline
            last = exc
            time.sleep(0.05)
            continue
        candidate.close()
        return path
    raise RuntimeNotFound(f"rvd did not answer at {path}: {last}")


def evaluate(
    command: str,
    cwd: str | os.PathLike[str] | None = None,
    packs: Iterable[str | models.PackID] | None = None,
    budget: int | None = None,
    socket_path: str | None = None,
) -> models.Evaluation:
    """One-shot ``Client.evaluate`` (connects, calls, closes)."""
    with Client(socket_path=socket_path) as client:
        return client.evaluate(command, cwd, packs, budget)


def explain(
    command: str,
    cwd: str | os.PathLike[str] | None = None,
    packs: Iterable[str | models.PackID] | None = None,
    budget: int | None = None,
    socket_path: str | None = None,
) -> models.Explanation:
    """One-shot ``Client.explain`` (connects, calls, closes)."""
    with Client(socket_path=socket_path) as client:
        return client.explain(command, cwd, packs, budget)


def classify(
    command: str,
    cwd: str | os.PathLike[str] | None = None,
    packs: Iterable[str | models.PackID] | None = None,
    budget: int | None = None,
    socket_path: str | None = None,
) -> models.Classification:
    """One-shot ``Client.classify`` (connects, calls, closes)."""
    with Client(socket_path=socket_path) as client:
        return client.classify(command, cwd, packs, budget)
