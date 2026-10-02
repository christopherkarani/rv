"""Transport: path resolution, mode checks, and framed round-trips against a
scripted fake server (real AF_UNIX socket, no rvd).
"""

from __future__ import annotations

import json
import os
import socket
import stat
import struct
import threading

import pytest

from rv import frames, transports
from rv.errors import (
    ConnectionFailed,
    RuntimeNotFound,
    SocketPathTooLong,
    Timeout,
)


def _frame(body: bytes) -> bytes:
    return struct.pack(">I", len(body)) + body


def _read_exact(conn: socket.socket, count: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < count:
        chunk = conn.recv(count - len(chunks))
        if not chunk:
            raise ConnectionError("eof")
        chunks += chunk
    return bytes(chunks)


class FakeServer:
    """Scripted single-connection Unix socket server for transport tests."""

    def __init__(self, path: str, replies: list[bytes], delay: float = 0.0) -> None:
        self.path = path
        self.replies = list(replies)
        self.delay = delay
        self.received: list[bytes] = []
        self._thread: threading.Thread | None = None
        self._listener: socket.socket | None = None

    def __enter__(self) -> FakeServer:
        import time

        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(self.path)
        os.chmod(self.path, 0o600)
        listener.listen(1)
        listener.settimeout(10)
        self._listener = listener

        def serve() -> None:
            try:
                conn, _ = listener.accept()
            except OSError:
                return
            with conn:
                while self.replies:
                    try:
                        header = _read_exact(conn, 4)
                        (length,) = struct.unpack(">I", header)
                        body = _read_exact(conn, length)
                    except OSError:
                        return
                    self.received.append(body)
                    if self.delay:
                        time.sleep(self.delay)
                    try:
                        conn.sendall(_frame(self.replies.pop(0)))
                    except OSError:
                        return

        self._thread = threading.Thread(target=serve, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, *exc: object) -> None:
        if self._listener is not None:
            try:
                self._listener.close()
            except OSError:
                pass
            self._listener = None
        if self._thread is not None:
            self._thread.join(timeout=10)
            self._thread = None
        try:
            os.unlink(self.path)
        except OSError:
            pass


def test_resolve_linux_xdg(monkeypatch):
    monkeypatch.setattr(transports.sys, "platform", "linux")
    monkeypatch.setenv("XDG_RUNTIME_DIR", "/run/user/1")
    assert transports.resolve_socket_path() == "/run/user/1/rv/evaluate.sock"
    monkeypatch.setenv("XDG_RUNTIME_DIR", "  /run/user/1\n")
    assert transports.resolve_socket_path() == "/run/user/1/rv/evaluate.sock"


def test_resolve_linux_missing_base_fails_closed(monkeypatch):
    monkeypatch.setattr(transports.sys, "platform", "linux")
    for value in ["", "   "]:
        monkeypatch.setenv("XDG_RUNTIME_DIR", value)
        with pytest.raises(RuntimeNotFound):
            transports.resolve_socket_path()
    monkeypatch.delenv("XDG_RUNTIME_DIR", raising=False)
    with pytest.raises(RuntimeNotFound) as info:
        transports.resolve_socket_path()
    assert "install" in info.value.remediation


def test_resolve_linux_too_long(monkeypatch):
    monkeypatch.setattr(transports.sys, "platform", "linux")
    monkeypatch.setenv("XDG_RUNTIME_DIR", "/" + "x" * 120)
    with pytest.raises(SocketPathTooLong) as info:
        transports.resolve_socket_path()
    assert info.value.path


def test_resolve_darwin_home(monkeypatch):
    monkeypatch.setattr(transports.sys, "platform", "darwin")
    monkeypatch.setenv("HOME", "/Users/x")
    assert transports.resolve_socket_path() == "/Users/x/.config/rv/evaluate.sock"


def test_resolve_darwin_missing_home_fails_closed(monkeypatch):
    monkeypatch.setattr(transports.sys, "platform", "darwin")
    monkeypatch.delenv("HOME", raising=False)
    with pytest.raises(RuntimeNotFound):
        transports.resolve_socket_path()


def test_resolve_darwin_cap_is_104(monkeypatch):
    monkeypatch.setattr(transports.sys, "platform", "darwin")
    # 78-char HOME + 25-char suffix + NUL = 104: fits.
    monkeypatch.setenv("HOME", "/" + "x" * 77)
    transports.resolve_socket_path()
    # One more char overflows.
    monkeypatch.setenv("HOME", "/" + "x" * 78)
    with pytest.raises(SocketPathTooLong):
        transports.resolve_socket_path()


def test_resolve_explicit_path_is_length_checked(monkeypatch):
    assert transports.resolve_socket_path("/tmp/x.sock") == "/tmp/x.sock"
    with pytest.raises(SocketPathTooLong):
        transports.resolve_socket_path("/" + "x" * 200 + ".sock")


def test_resolve_unsupported_platform(monkeypatch):
    monkeypatch.setattr(transports.os, "name", "nt")
    with pytest.raises(RuntimeNotFound):
        transports.resolve_socket_path()


def test_connect_missing_socket_is_not_found(tmp_path):
    # Short on purpose: tmp_path-based names overflow the Darwin cap.
    missing = f"/tmp/rv-missing-{os.getpid()}/evaluate.sock"
    transport = transports.UnixSocketTransport(socket_path=missing)
    with pytest.raises(RuntimeNotFound) as info:
        transport.connect()
    assert info.value.path == missing
    assert "install" in info.value.remediation


def test_connect_non_socket_is_refused():
    # Short on purpose: tmp_path-based names overflow the Darwin cap.
    regular = f"/tmp/rv-plain-{os.getpid()}"
    with open(regular, "w") as handle:
        handle.write("x")
    os.chmod(regular, 0o600)
    try:
        transport = transports.UnixSocketTransport(socket_path=regular)
        with pytest.raises(ConnectionFailed):
            transport.connect()
    finally:
        os.unlink(regular)


def test_connect_wrong_mode_is_refused(socket_path):
    path = socket_path
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(path)
    try:
        os.chmod(path, 0o644)
        transport = transports.UnixSocketTransport(socket_path=path)
        with pytest.raises(ConnectionFailed):
            transport.connect()
    finally:
        listener.close()
        os.unlink(path)


def test_connect_wrong_parent_mode_is_refused(socket_path):
    path = socket_path
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(path)
    try:
        os.chmod(path, 0o600)
        os.chmod(os.path.dirname(path), 0o755)
        transport = transports.UnixSocketTransport(socket_path=path)
        with pytest.raises(ConnectionFailed):
            transport.connect()
    finally:
        os.chmod(os.path.dirname(path), 0o700)
        listener.close()
        os.unlink(path)


def test_round_trip_against_fake_server(socket_path):
    path = socket_path
    ack = b'{"ok":true,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0"}'
    with FakeServer(path, [ack]):
        transport = transports.UnixSocketTransport(socket_path=path)
        transport.connect()
        try:
            assert transport.path == path
            reply = transport.round_trip(b'{"protocol":"rv.ipc.v1","clientSemver":"1.0.0"}')
            assert json.loads(reply)["ok"] is True
        finally:
            transport.close()
            transport.close()  # idempotent


def test_round_trip_requires_connect():
    transport = transports.UnixSocketTransport(socket_path="/tmp/never.sock")
    with pytest.raises(ConnectionFailed):
        transport.round_trip(b"{}")


def test_round_trip_timeout(socket_path):
    path = socket_path
    ack = b'{"ok":true,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0"}'
    with FakeServer(path, [ack], delay=0.5):
        transport = transports.UnixSocketTransport(socket_path=path)
        transport.connect()
        try:
            with pytest.raises(Timeout) as info:
                transport.round_trip(b"{}", timeout=0.1)
            assert info.value.timeout == 0.1
        finally:
            transport.close()


def test_round_trip_eof_is_connection_failed(socket_path):
    path = socket_path
    with FakeServer(path, []):
        transport = transports.UnixSocketTransport(socket_path=path)
        transport.connect()
        try:
            with pytest.raises(ConnectionFailed):
                transport.round_trip(b"{}", timeout=5)
        finally:
            transport.close()


def test_round_trip_oversized_body_rejected_locally(socket_path):
    path = socket_path
    with FakeServer(path, [b"{}"]):
        transport = transports.UnixSocketTransport(socket_path=path)
        transport.connect()
        try:
            with pytest.raises(Exception) as info:
                transport.round_trip(b"x" * (frames.MAX_BODY_BYTES + 1))
            assert getattr(info.value, "kind", None) == "oversized"
        finally:
            transport.close()


def test_same_socket_detects_replacement(socket_path):
    first = socket_path
    second = socket_path + "2"
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(first)
    try:
        os.chmod(first, 0o600)
        info = os.lstat(first)
        assert transports._same_socket((info.st_dev, info.st_ino), first) is True
        other = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        other.bind(second)
        try:
            assert transports._same_socket((info.st_dev, info.st_ino), second) is False
        finally:
            other.close()
            os.unlink(second)
        gone = os.path.join(os.path.dirname(first), "gone")
        assert transports._same_socket((info.st_dev, info.st_ino), gone) is False
    finally:
        listener.close()
        os.unlink(first)


def test_socket_stat_mode_bits(socket_path):
    path = socket_path
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(path)
    try:
        os.chmod(path, 0o600)
        dev, ino = transports._stat_socket(path)
        info = os.lstat(path)
        assert (dev, ino) == (info.st_dev, info.st_ino)
        assert stat.S_IMODE(info.st_mode) == 0o600
    finally:
        listener.close()
        os.unlink(path)
