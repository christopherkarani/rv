"""Socket transport for ``rv.ipc.v1``. See ``sdk/WIRE.md`` §1-§2, §6.

Linux resolves ``$XDG_RUNTIME_DIR/rv/evaluate.sock``; macOS resolves
``$HOME/.config/rv/evaluate.sock`` — the same rules as
``Sources/RVService/UnixSocketPath.swift``, including fail-closed base dirs,
``sockaddr_un`` length caps, and owner-only mode *checks* (the SDK never
repairs permissions). One-shot budgets mirror ``ServiceTransport``: 200 ms
connect, 700 ms default per call.
"""

from __future__ import annotations

import abc
import os
import socket
import stat
import sys

from . import frames
from .errors import ConnectionFailed, RuntimeNotFound, SocketPathTooLong, Timeout

CONNECT_TIMEOUT = 0.2
DEFAULT_CALL_TIMEOUT = 0.7
_LINUX_MAX_PATH = 108
_DARWIN_MAX_PATH = 104
_INSTALL_HINT = "install RV: curl -fsSL https://rykanv.com/install | sh (then `rv setup`)"


class Transport(abc.ABC):
    """Byte transport: connect, framed round-trip, close."""

    @abc.abstractmethod
    def connect(self, timeout: float = CONNECT_TIMEOUT) -> None:
        """Connect. Raises ``ConnectionFailed`` / ``RuntimeNotFound``."""

    @abc.abstractmethod
    def close(self) -> None:
        """Close. Idempotent."""

    @abc.abstractmethod
    def round_trip(self, body: bytes, timeout: float = DEFAULT_CALL_TIMEOUT) -> bytes:
        """Send one framed body, return the reply body."""


def resolve_socket_path(explicit: str | None = None) -> str:
    """Resolve the production socket path for this platform.

    ``explicit`` overrides discovery (tests/tools) but is still length-checked.
    Raises ``RuntimeNotFound`` (missing base dir, unsupported platform) or
    ``SocketPathTooLong``.
    """
    if explicit is not None:
        return _check_length(explicit)
    if os.name != "posix":
        raise RuntimeNotFound(
            f"rv supports macOS and Linux only (this platform: {os.name})",
            remediation=_INSTALL_HINT,
        )
    if sys.platform == "darwin":
        base = (os.environ.get("HOME") or "").strip()
        if not base:
            raise RuntimeNotFound(
                "HOME is unset or empty; cannot locate $HOME/.config/rv/evaluate.sock",
                remediation=_INSTALL_HINT,
            )
        return _check_length(os.path.join(base, ".config", "rv", "evaluate.sock"))
    base = (os.environ.get("XDG_RUNTIME_DIR") or "").strip()
    if not base:
        raise RuntimeNotFound(
            "XDG_RUNTIME_DIR is unset or empty; cannot locate $XDG_RUNTIME_DIR/rv/evaluate.sock",
            remediation=_INSTALL_HINT,
        )
    return _check_length(os.path.join(base, "rv", "evaluate.sock"))


def _check_length(path: str) -> str:
    budget = _DARWIN_MAX_PATH if sys.platform == "darwin" else _LINUX_MAX_PATH
    if len(path.encode("utf-8")) + 1 > budget:
        raise SocketPathTooLong(
            f"socket path too long for sockaddr_un ({budget - 1} bytes max): {path}",
            path=path,
        )
    return path


def _stat_socket(path: str) -> tuple[int, int]:
    """lstat a socket path, enforcing type/owner/mode. Returns (dev, ino).

    Raises ``RuntimeNotFound`` when absent, ``ConnectionFailed`` when present
    but unusable. Never repairs anything.
    """
    try:
        info = os.lstat(path)
    except FileNotFoundError as exc:
        raise RuntimeNotFound(
            f"rvd socket not found: {path} (is rvd running? see rv.ensure_runtime)",
            path=path,
            remediation=_INSTALL_HINT,
        ) from exc
    except OSError as exc:
        raise ConnectionFailed(f"cannot stat rvd socket {path}: {exc}") from exc
    if not stat.S_ISSOCK(info.st_mode):
        raise ConnectionFailed(f"rvd socket path is not a socket: {path}")
    if info.st_uid != os.getuid():
        raise ConnectionFailed(f"rvd socket is not owned by uid {os.getuid()}: {path}")
    if stat.S_IMODE(info.st_mode) != 0o600:
        raise ConnectionFailed(f"rvd socket is not owner-only (0600): {path}")
    return (info.st_dev, info.st_ino)


def _check_parent_modes(path: str) -> None:
    """Require safe parent dirs: the ``rv`` dir must be 0700 owned by this
    uid; the base dir (``$XDG_RUNTIME_DIR``, ``$HOME/.config``) must exist
    owned by this uid and must not be group/world-writable.

    Mirrors what ``UnixSocketPath.prepareRuntime`` establishes: the server
    owns only the ``rv`` dir and never chmods a pre-existing base. Mismatch
    is ``ConnectionFailed``: the SDK reports, never repairs.
    """
    inner = os.path.dirname(path)
    try:
        info = os.stat(inner)
    except OSError as exc:
        raise ConnectionFailed(f"cannot stat socket dir {inner}: {exc}") from exc
    if info.st_uid != os.getuid():
        raise ConnectionFailed(f"socket dir not owned by uid {os.getuid()}: {inner}")
    if stat.S_IMODE(info.st_mode) != 0o700:
        raise ConnectionFailed(f"socket dir is not owner-only (0700): {inner}")
    base = os.path.dirname(inner)
    try:
        base_info = os.stat(base)
    except OSError as exc:
        raise ConnectionFailed(f"cannot stat socket dir {base}: {exc}") from exc
    if base_info.st_uid != os.getuid():
        raise ConnectionFailed(f"socket dir not owned by uid {os.getuid()}: {base}")
    if stat.S_IMODE(base_info.st_mode) & 0o022:
        raise ConnectionFailed(f"socket base dir is group/world-writable: {base}")


def _same_socket(before: tuple[int, int], path: str) -> bool:
    """True when ``path`` still names the (dev, ino) seen in ``before``.

    Re-lstat after connect to catch path swaps between the pre-connect checks
    and ``connect()``. A swap-and-restore inside the race window is a residual
    same-user risk, documented in ``sdk/WIRE.md`` §1.
    """
    try:
        info = os.lstat(path)
    except OSError:
        return False
    return (info.st_dev, info.st_ino) == before


class UnixSocketTransport(Transport):
    """Framed JSON over the production AF_UNIX socket. Not thread-safe:
    one connection per thread.
    """

    def __init__(self, socket_path: str | None = None) -> None:
        self._override = socket_path
        self._path: str | None = None
        self._sock: socket.socket | None = None

    @property
    def path(self) -> str | None:
        """Resolved socket path after ``connect()``, else ``None``."""
        return self._path

    def connect(self, timeout: float = CONNECT_TIMEOUT) -> None:
        if self._sock is not None:
            return
        path = resolve_socket_path(self._override)
        identity = _stat_socket(path)
        _check_parent_modes(path)
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.settimeout(timeout)
            sock.connect(path)
        except OSError as exc:
            # Includes socket.timeout (a TimeoutError/OSError): connect budget spent.
            sock.close()
            raise ConnectionFailed(f"cannot connect to rvd at {path}: {exc}") from exc
        if not _same_socket(identity, path):
            sock.close()
            raise ConnectionFailed(f"rvd socket was replaced during connect: {path}")
        self._path = path
        self._sock = sock

    def close(self) -> None:
        sock, self._sock = self._sock, None
        self._path = None
        if sock is not None:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            sock.close()

    def round_trip(self, body: bytes, timeout: float = DEFAULT_CALL_TIMEOUT) -> bytes:
        sock = self._sock
        if sock is None:
            raise ConnectionFailed("transport is not connected")
        frame = frames.encode(body)
        try:
            sock.settimeout(timeout)
            sock.sendall(frame)
            header = _recv_exact(sock, 4)
            length = frames.body_count(header)
            payload = _recv_exact(sock, length)
        except TimeoutError as exc:
            # socket.timeout is TimeoutError since 3.10.
            raise Timeout(f"rvd call exceeded {timeout}s", timeout=timeout) from exc
        except OSError as exc:
            raise ConnectionFailed(f"rvd connection failed: {exc}") from exc
        # FrameError (an RvError, not OSError) propagates untouched.
        return frames.decode_split(header, payload)

    def __enter__(self) -> UnixSocketTransport:
        self.connect()
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()


def _recv_exact(sock: socket.socket, count: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < count:
        chunk = sock.recv(count - len(chunks))
        if not chunk:
            raise ConnectionFailed("rvd closed the connection (EOF)")
        chunks += chunk
    return bytes(chunks)
