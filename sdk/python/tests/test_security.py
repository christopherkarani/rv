"""Fail-closed security regressions. Every test asserts the SDK refuses,
surfaces a typed error, or sends verbatim echoes for the service to judge —
never substitutes its own authority. Scripted transports (no daemon); live
forgery cases run in ``test_integration.py``.
"""

from __future__ import annotations

import json
import os
import uuid

import pytest
import test_client

from rv import models, protocol, transports
from rv.errors import (
    ConnectionFailed,
    DecodeError,
    MajorVersionSkew,
    PendingAlreadyTerminal,
    PendingFingerprintMismatch,
    PendingIdentityMismatch,
    PendingNotFound,
)

ACK_OK = test_client.ACK_OK


def _item(**overrides) -> models.PendingItem:
    base = {
        "id": "ask-1",
        "host": "pi",
        "folder": "ws",
        "actionKind": "git push",
        "fingerprint": "shell:git",
        "identity": {"session": "sess", "agent": "pi"},
    }
    base.update(overrides)
    return models.PendingItem.from_wire(base)


def test_forged_approval_id_surfaces_not_found():
    def _reply(request: dict) -> bytes:
        assert json.loads(json.dumps(request))["method"]["pendingResolve"]["id"] == "forged"
        return test_client.respond_error({"pendingNotFound": True})(request)

    client, _ = test_client._connected(_reply)
    forged = _item(id="forged")
    with pytest.raises(PendingNotFound):
        client.pending_resolve(forged, allow=True)


def test_tampered_fingerprint_is_echoed_verbatim_for_service_verdict():
    def _reply(request: dict) -> bytes:
        params = request["method"]["pendingResolve"]
        assert params["fingerprint"] == "tampered"
        return test_client.respond_error({"pendingFingerprintMismatch": True})(request)

    client, transport = test_client._connected(_reply)
    with pytest.raises(PendingFingerprintMismatch):
        client.pending_resolve(_item(fingerprint="tampered"), allow=True)
    sent = json.loads(transport.received[1])["method"]["pendingResolve"]
    assert sent["fingerprint"] == "tampered"


def test_tampered_identity_is_echoed_verbatim_for_service_verdict():
    def _reply(request: dict) -> bytes:
        params = request["method"]["pendingResolve"]
        assert params["identity"] == {"session": "other", "agent": "pi"}
        return test_client.respond_error({"pendingIdentityMismatch": True})(request)

    client, transport = test_client._connected(_reply)
    item = _item(identity={"session": "other", "agent": "pi"})
    with pytest.raises(PendingIdentityMismatch):
        client.pending_resolve(item, allow=False)
    sent = json.loads(transport.received[1])["method"]["pendingResolve"]
    assert sent["identity"] == {"session": "other", "agent": "pi"}


def test_session_suffix_is_display_only_and_never_sent():
    def _reply(request: dict) -> bytes:
        assert "sessionSuffix" not in request["method"]["pendingResolve"]
        return test_client.respond_error({"pendingNotFound": True})(request)

    client, _ = test_client._connected(_reply)
    with pytest.raises(PendingNotFound):
        client.pending_resolve(_item(sessionSuffix="evil-suffix"), allow=True)


def test_double_resolve_surfaces_terminal():
    ok = json.dumps(
        {
            "id": "PLACEHOLDER",
            "protocol": "rv.ipc.v1",
            "result": {"pendingResolve": {"id": "ask-1", "terminal": True}},
        }
    ).encode()

    def _first(request: dict) -> bytes:
        obj = json.loads(ok)
        obj["id"] = request["id"]
        return json.dumps(obj).encode()

    client, _ = test_client._connected(
        _first, test_client.respond_error({"pendingAlreadyTerminal": True})
    )
    item = _item()
    assert client.pending_resolve(item, allow=True).terminal is True
    with pytest.raises(PendingAlreadyTerminal):
        client.pending_resolve(item, allow=True)


def test_request_ids_are_fresh_per_call():
    def _reply(request: dict) -> bytes:
        return json.dumps(
            {
                "id": request["id"],
                "protocol": "rv.ipc.v1",
                "result": {"pendingList": {"generation": 0, "items": []}},
            }
        ).encode()

    client, transport = test_client._connected(_reply, _reply)
    client.pending_list()
    client.pending_list()
    first = json.loads(transport.received[1])["id"]
    second = json.loads(transport.received[2])["id"]
    assert first != second
    uuid.UUID(first)
    uuid.UUID(second)


def test_version_downgrade_is_hard_error_not_compat():
    for service in ("0.9.9", "garbage", ""):
        ack = json.dumps({"ok": True, "protocol": "rv.ipc.v1", "serviceSemver": service}).encode()
        client, _ = test_client._client(ack)
        with pytest.raises(MajorVersionSkew):
            client.connect()


def test_reply_downgrade_is_hard_error():
    def _reply(request: dict) -> bytes:
        return json.dumps(
            {
                "id": request["id"],
                "protocol": "rv.ipc.v1",
                "result": {
                    "evaluate": {
                        "result": {"decision": {"decision": "allow"}},
                        "via": "xpc",
                        "serviceSemver": "0.9.9",
                    }
                },
            }
        ).encode()

    client, _ = test_client._connected(_reply)
    with pytest.raises(MajorVersionSkew):
        client.evaluate("echo hi")


def test_unknown_wire_shapes_fail_closed():
    with pytest.raises(DecodeError):
        protocol.decode_ipc_error({"futureError": True})
    with pytest.raises(DecodeError):
        models.ApprovalIdentity.from_wire({"session": "s", "agent": "evil-host"})
    with pytest.raises(DecodeError):
        models.Evaluation.from_wire({"decision": {"decision": "allow"}, "matched": {}})


def test_wrong_mode_socket_refused_without_repair(socket_path):
    import socket

    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(socket_path)
    try:
        os.chmod(socket_path, 0o644)
        transport = transports.UnixSocketTransport(socket_path=socket_path)
        with pytest.raises(ConnectionFailed):
            transport.connect()
        # Report, never repair: mode must be untouched.
        assert oct(os.stat(socket_path).st_mode & 0o777) == oct(0o644)
    finally:
        listener.close()
        os.unlink(socket_path)


def test_cross_uid_socket_refused(monkeypatch, socket_path):
    import socket

    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(socket_path)
    try:
        os.chmod(socket_path, 0o600)
        # Fake a foreign owner: exercises the uid-mismatch branch (the kernel
        # enforces the real boundary; see also the getpeereid gate in rvd).
        foreign = os.getuid() + 1
        monkeypatch.setattr(transports.os, "getuid", lambda: foreign)
        transport = transports.UnixSocketTransport(socket_path=socket_path)
        with pytest.raises(ConnectionFailed):
            transport.connect()
    finally:
        listener.close()
        os.unlink(socket_path)


def test_cwd_and_packs_validated_before_send():
    client, transport = test_client._connected()
    with pytest.raises(ValueError):
        client.evaluate("ls", cwd="")
    with pytest.raises(ValueError):
        client.evaluate("ls", packs="core.git")
    with pytest.raises(ValueError):
        client.evaluate("ls", packs=["Bogus!"])
    assert len(transport.received) == 1  # Hello only: nothing was sent
