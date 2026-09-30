"""Envelope, method/result, and IPCError codec (``sdk/WIRE.md`` §§3-5, §7)."""

from __future__ import annotations

import json
import uuid

import pytest

from rv import protocol
from rv.errors import (
    AllowOnceAlreadyConsumed,
    AllowOnceExpired,
    AllowOnceNotFound,
    AllowOnceNotUnlockable,
    CoordinatorUnavailable,
    DecodeError,
    EngineError,
    HandshakeRequired,
    HookEvaluateFailed,
    MajorVersionSkew,
    PackEnableFailed,
    PackNotFound,
    PendingAlreadyTerminal,
    PendingFingerprintMismatch,
    PendingIdentityMismatch,
    PendingNotFound,
    ProtocolSkew,
    RuleDraftMismatch,
    RuleHardStop,
    RulePinRequiresMatchingView,
    UnexpectedResult,
    UnknownMethod,
    raise_for_ipc_error,
)

UID = uuid.UUID("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")


def _response(result: object, request_id: uuid.UUID = UID) -> bytes:
    return json.dumps(
        {"id": str(request_id).upper(), "protocol": "rv.ipc.v1", "result": result}
    ).encode()


def test_hello_encodes_golden():
    assert protocol.Hello().encode() == b'{"clientSemver":"1.0.0","protocol":"rv.ipc.v1"}'


def test_hello_ack_ok_and_skews():
    ack = protocol.HelloAck.decode(b'{"ok":true,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0"}')
    assert (ack.protocol, ack.service_semver, ack.ok, ack.skew_reason) == (
        "rv.ipc.v1",
        "1.0.0",
        True,
        None,
    )
    for wire, reason in [
        ("protocol", "protocol"),
        ("major version", "major version"),
        ("core packs unavailable", "core packs unavailable"),
    ]:
        skewed = protocol.HelloAck.decode(
            json.dumps(
                {
                    "ok": False,
                    "protocol": "rv.ipc.v1",
                    "serviceSemver": "1.0.0",
                    "skewReason": wire,
                }
            ).encode()
        )
        assert skewed.ok is False
        assert skewed.skew_reason == reason


def test_hello_ack_combo_violations_fail_closed():
    with pytest.raises(DecodeError):
        protocol.HelloAck.decode(
            b'{"ok":true,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0",'
            b'"skewReason":"major version"}'
        )
    with pytest.raises(DecodeError):
        protocol.HelloAck.decode(b'{"ok":false,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0"}')
    with pytest.raises(DecodeError):
        protocol.HelloAck.decode(b'{"ok":true,"protocol":"rv.ipc.v1"}')
    with pytest.raises(DecodeError):
        protocol.HelloAck.decode(b"not-json")
    with pytest.raises(DecodeError):
        protocol.HelloAck.decode(b"[1,2]")


def test_unknown_keys_are_ignored():
    ack = protocol.HelloAck.decode(
        b'{"ok":true,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0","future":1,'
        b'"capabilities":["pending-watch"]}'
    )
    assert ack.ok is True


def test_uuid_parses_any_case_and_emits_uppercase():
    assert protocol.parse_uuid("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee") == UID
    assert protocol.parse_uuid("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") == UID
    assert protocol.format_uuid(UID) == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    with pytest.raises(DecodeError):
        protocol.parse_uuid("not-a-uuid")
    with pytest.raises(DecodeError):
        protocol.parse_uuid(42)


def test_wire_request_round_trip():
    req = protocol.WireRequest(id=UID, method="listPacks", params={})
    assert req.encode() == (
        b'{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",'
        b'"method":{"listPacks":{}},"protocol":"rv.ipc.v1"}'
    )
    decoded = protocol.WireRequest.decode(req.encode())
    assert decoded == req
    with pytest.raises(DecodeError):
        protocol.WireRequest.decode(b'{"id":"x","protocol":"rv.ipc.v1","method":{}}')


def test_decode_response_returns_payload_and_verifies_echo():
    payload = protocol.decode_response(
        _response({"listPacks": {"packs": []}}), request_id=UID, method="listPacks"
    )
    assert payload == {"packs": []}


def test_decode_response_rejects_echo_mismatch_and_wrong_variant():
    other = uuid.uuid4()
    with pytest.raises(UnexpectedResult):
        protocol.decode_response(_response({"listPacks": {}}), request_id=other, method="listPacks")
    bad_protocol = json.dumps(
        {"id": str(UID).upper(), "protocol": "rv.ipc.v0", "result": {"listPacks": {}}}
    ).encode()
    with pytest.raises(UnexpectedResult):
        protocol.decode_response(bad_protocol, request_id=UID, method="listPacks")
    with pytest.raises(UnexpectedResult):
        protocol.decode_response(
            _response({"doctorSnapshot": {}}), request_id=UID, method="listPacks"
        )
    with pytest.raises(DecodeError):
        protocol.decode_response(b"{}", request_id=UID, method="listPacks")


def test_decode_response_surfaces_errors_as_typed_exceptions():
    with pytest.raises(PendingNotFound):
        protocol.decode_response(
            _response({"error": {"pendingNotFound": True}}), request_id=UID, method="pendingList"
        )
    with pytest.raises(MajorVersionSkew):
        protocol.decode_response(
            _response({"error": {"protocolSkew": "major version"}}),
            request_id=UID,
            method="evaluate",
        )


def test_ipc_error_unit_cases_decode_by_presence():
    cases = {
        "unknownMethod": UnknownMethod,
        "decodeFailed": DecodeError,
        "allowOnceNotFound": AllowOnceNotFound,
        "allowOnceAlreadyConsumed": AllowOnceAlreadyConsumed,
        "allowOnceExpired": AllowOnceExpired,
        "pendingNotFound": PendingNotFound,
        "pendingAlreadyTerminal": PendingAlreadyTerminal,
        "pendingIdentityMismatch": PendingIdentityMismatch,
        "pendingFingerprintMismatch": PendingFingerprintMismatch,
        "ruleDraftMismatch": RuleDraftMismatch,
        "ruleHardStop": RuleHardStop,
    }
    for key, exc in cases.items():
        value = protocol.decode_ipc_error({key: True})
        assert value.kind == key
        with pytest.raises(exc):
            raise_for_ipc_error(value)
    # Presence, not truthiness, mirrors Swift's container.contains quirk.
    assert protocol.decode_ipc_error({"unknownMethod": False}).kind == "unknownMethod"
    assert protocol.decode_ipc_error({"pendingNotFound": None}).kind == "pendingNotFound"


def test_ipc_error_decode_order_is_normative():
    # unknownMethod wins over decodeFailed; decodeFailed wins over engine.
    assert protocol.decode_ipc_error({"unknownMethod": True, "decodeFailed": True}).kind == (
        "unknownMethod"
    )
    assert protocol.decode_ipc_error({"decodeFailed": True, "engine": "x"}).kind == "decodeFailed"
    assert (
        protocol.decode_ipc_error({"protocolSkew": "protocol", "pendingNotFound": True}).kind
        == "protocolSkew"
    )


def test_ipc_error_valued_cases():
    assert protocol.decode_ipc_error({"protocolSkew": "handshake required"}).payload == (
        "handshake required"
    )
    assert protocol.decode_ipc_error({"packNotFound": "core.git"}) == protocol.decode_ipc_error(
        {"packNotFound": "core.git"}
    )
    with pytest.raises(PackNotFound) as info:
        raise_for_ipc_error(protocol.decode_ipc_error({"packNotFound": "core.git"}))
    assert info.value.pack_id == "core.git"
    with pytest.raises(DecodeError):
        protocol.decode_ipc_error({"packNotFound": 42})
    with pytest.raises(DecodeError):
        protocol.decode_ipc_error({"protocolSkew": None})


def test_ipc_error_engine_sentences():
    table = {
        "hook evaluate failed": HookEvaluateFailed,
        "pack enable failed": PackEnableFailed,
        "rule pin requires a matching view": RulePinRequiresMatchingView,
        "pending allowOnce is not unlockable": AllowOnceNotUnlockable,
        "pending coordinator unavailable": CoordinatorUnavailable,
    }
    for sentence, exc in table.items():
        with pytest.raises(exc):
            raise_for_ipc_error(protocol.decode_ipc_error({"engine": sentence}))
    leftover = protocol.decode_ipc_error({"engine": "something the service never owned"})
    assert leftover.kind == "engine"
    assert leftover.payload == "something the service never owned"
    with pytest.raises(EngineError):
        raise_for_ipc_error(leftover)


def test_ipc_error_skew_reasons_map():
    with pytest.raises(HandshakeRequired):
        raise_for_ipc_error(protocol.decode_ipc_error({"protocolSkew": "handshake required"}))
    with pytest.raises(ProtocolSkew):
        raise_for_ipc_error(protocol.decode_ipc_error({"protocolSkew": "protocol"}))
    with pytest.raises(MajorVersionSkew):
        raise_for_ipc_error(protocol.decode_ipc_error({"protocolSkew": "major version"}))


def test_ipc_error_unknown_shape_fails_closed():
    with pytest.raises(DecodeError):
        protocol.decode_ipc_error({"somethingNew": True})
    with pytest.raises(DecodeError):
        protocol.decode_ipc_error("nope")


def test_decode_result_object():
    ok = protocol.decode_result_object({"pendingList": {"generation": 1}})
    assert ok.method == "pendingList"
    assert ok.payload == {"generation": 1}
    assert not ok.is_error
    err = protocol.decode_result_object({"error": {"pendingNotFound": True}})
    assert err.is_error and err.error is not None and err.error.kind == "pendingNotFound"
    with pytest.raises(DecodeError):
        protocol.decode_result_object({"nope": {}})
