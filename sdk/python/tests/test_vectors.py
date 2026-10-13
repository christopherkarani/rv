"""Shared golden bytes: the same literals as ``Tests/RVIPCTests/SDKVectorTests.swift``
(plus the hookEvaluate goldens from ``HookEvaluateRoundTripTests``).

Any change to these bytes is a wire change and requires a version decision per
``sdk/VERSIONING.md``. Each vector is asserted byte-exact (canonical re-emit)
and semantically decoded.
"""

from __future__ import annotations

import json
import uuid

from rv import protocol

UID = uuid.UUID("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")

HANDSHAKE = [
    b'{"clientSemver":"1.0.0","protocol":"rv.ipc.v1"}',
    b'{"ok":true,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0"}',
    b'{"ok":false,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0","skewReason":"protocol"}',
    b'{"ok":false,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0","skewReason":"major version"}',
    (
        b'{"ok":false,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0",'
        b'"skewReason":"core packs unavailable"}'
    ),
]

REQUESTS = {
    "evaluate": (
        b'{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","method":{"evaluate":{"request":'
        b'{"command":"git reset --hard","enabledPacks":["core.filesystem","core.git",'
        b'"system.disk"]}}},"protocol":"rv.ipc.v1"}'
    ),
    "explain": (
        b'{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","method":{"explain":{"request":'
        b'{"command":"git reset --hard","enabledPacks":["core.filesystem","core.git",'
        b'"system.disk"]}}},"protocol":"rv.ipc.v1"}'
    ),
    "classify": (
        b'{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","method":{"classify":{"request":'
        b'{"command":"git reset --hard","enabledPacks":["core.filesystem","core.git",'
        b'"system.disk"]}}},"protocol":"rv.ipc.v1"}'
    ),
    "hookEvaluate": (
        b'{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","method":{"hookEvaluate":'
        b'{"clientSemver":"1.0.0","host":"grok","stdin":"{\\"tool\\":\\"Bash\\"}"}},'
        b'"protocol":"rv.ipc.v1"}'
    ),
    "listPacks": (
        b'{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","method":{"listPacks":{}},'
        b'"protocol":"rv.ipc.v1"}'
    ),
    "setPackEnabled": (
        b'{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","method":{"setPackEnabled":'
        b'{"enabled":true,"id":"core.git"}},"protocol":"rv.ipc.v1"}'
    ),
    "doctorSnapshot": (
        b'{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","method":{"doctorSnapshot":{}},'
        b'"protocol":"rv.ipc.v1"}'
    ),
    "pendingList": (
        b'{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","method":{"pendingList":{}},'
        b'"protocol":"rv.ipc.v1"}'
    ),
    "pendingWatch": (
        b'{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","method":{"pendingWatch":'
        b'{"afterGeneration":0}},"protocol":"rv.ipc.v1"}'
    ),
    "pendingResolve": (
        b'{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","method":{"pendingResolve":'
        b'{"decision":"deny","fingerprint":"shell:git","id":"ask-1","identity":'
        b'{"agent":"pi","session":"sess"}}},"protocol":"rv.ipc.v1"}'
    ),
    "rulePreview": (
        b'{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","method":{"rulePreview":'
        b'{"id":"ask-1","polarity":"allow"}},"protocol":"rv.ipc.v1"}'
    ),
    "ruleSave": (
        b'{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","method":{"ruleSave":'
        b'{"draft":"opaque-draft","id":"ask-1","polarity":"block"}},"protocol":"rv.ipc.v1"}'
    ),
}

RESPONSES = {
    "evaluate": (
        b'{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","protocol":"rv.ipc.v1",'
        b'"result":{"evaluate":{"result":{"decision":{"decision":"deny","reason":"destroys '
        b'uncommitted changes","ruleID":"core.git:reset-hard"},"matchingView":"",'
        b'"quickRejected":false},"serviceSemver":"1.0.0","via":"xpc"}}}'
    ),
    "explain": (
        b'{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","protocol":"rv.ipc.v1",'
        b'"result":{"explain":{"normalized":"git reset --hard","packID":"core.git","result":'
        b'{"decision":{"decision":"deny","reason":"destroys uncommitted changes","ruleID":'
        b'"core.git:reset-hard"},"matchingView":"","quickRejected":false},"ruleID":'
        b'"core.git:reset-hard","stages":[{"elapsedMs":0.1,"name":"normalize"}],'
        b'"suggestion":"Run it in Terminal, or rv allow-once."}}}'
    ),
    "classify": (
        b'{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","protocol":"rv.ipc.v1",'
        b'"result":{"classify":{"decision":{"decision":"deny","reason":"destroys uncommitted '
        b'changes","ruleID":"core.git:reset-hard"},"packID":"core.git","reasons":[],'
        b'"risk":"high","ruleID":"core.git:reset-hard","suggestions":[]}}}'
    ),
    "hookEvaluate": (
        b'{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","protocol":"rv.ipc.v1",'
        b'"result":{"hookEvaluate":{"exitCode":1,"serviceSemver":"1.0.0","stdout":"",'
        b'"via":"xpc"}}}'
    ),
    "listPacks": (
        b'{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","protocol":"rv.ipc.v1",'
        b'"result":{"listPacks":{"enabledCount":1,"packs":[{"bundled":true,"enabled":true,'
        b'"id":"core.git"}],"totalCount":1}}}'
    ),
    "setPackEnabled": (
        b'{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","protocol":"rv.ipc.v1",'
        b'"result":{"setPackEnabled":{"pack":{"bundled":true,"enabled":false,'
        b'"id":"core.git"}}}}'
    ),
    "doctorSnapshot": (
        b'{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","protocol":"rv.ipc.v1",'
        b'"result":{"doctorSnapshot":{"checks":[{"id":"xpc","message":"listener",'
        b'"status":"ok"}],"idleExitSeconds":300,"keepAlive":false,"label":"dev.rv.evaluate",'
        b'"packsEnabled":["core.git"],"protocol":"rv.ipc.v1","serviceSemver":"1.0.0",'
        b'"state":"running"}}}'
    ),
    "pendingList": (
        b'{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","protocol":"rv.ipc.v1",'
        b'"result":{"pendingList":{"generation":1,"items":[{"actionKind":"git push",'
        b'"fingerprint":"shell:git","folder":"ws","host":"pi","id":"ask-1","identity":'
        b'{"agent":"pi","session":"sess"}}]}}}'
    ),
    "pendingWatch": (
        b'{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","protocol":"rv.ipc.v1",'
        b'"result":{"pendingWatch":{"generation":1,"items":[]}}}'
    ),
    "pendingResolve": (
        b'{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","protocol":"rv.ipc.v1",'
        b'"result":{"pendingResolve":{"id":"ask-1","terminal":true}}}'
    ),
    "rulePreview": (
        b'{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","protocol":"rv.ipc.v1",'
        b'"result":{"rulePreview":{"allowedToSave":true,"draft":"opaque-draft","sentence":'
        b'"Always allow git push in this folder."}}}'
    ),
    "ruleSave": (
        b'{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","protocol":"rv.ipc.v1",'
        b'"result":{"ruleSave":{"ruleID":"core.git:reset-hard","waitResolved":true}}}'
    ),
    "error": (
        b'{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","protocol":"rv.ipc.v1",'
        b'"result":{"error":{"packNotFound":"core.unknown"}}}'
    ),
}


def _canonical(data: bytes) -> bytes:
    return json.dumps(json.loads(data), sort_keys=True, separators=(",", ":")).encode()


def test_every_vector_covers_a_wire_method():
    assert set(REQUESTS) == set(protocol.METHODS)
    assert set(RESPONSES) == set(protocol.METHODS) | {"error"}
    assert len(HANDSHAKE) == 5


def test_vectors_are_canonical_bytes():
    for raw in HANDSHAKE:
        assert _canonical(raw) == raw
    for name, raw in list(REQUESTS.items()) + list(RESPONSES.items()):
        assert _canonical(raw) == raw, f"vector drift: {name}"


def test_handshake_vectors_decode():
    acks = [protocol.HelloAck.decode(raw) for raw in HANDSHAKE[1:]]
    assert acks[0].ok is True
    assert [a.skew_reason for a in acks[1:]] == [
        "protocol",
        "major version",
        "core packs unavailable",
    ]


def test_request_vectors_decode_with_method_and_params():
    for name, raw in REQUESTS.items():
        req = protocol.WireRequest.decode(raw)
        assert req.id == UID
        assert req.method == name
        assert isinstance(req.params, dict)
    params = protocol.WireRequest.decode(REQUESTS["evaluate"]).params
    assert params["request"]["enabledPacks"] == ["core.filesystem", "core.git", "system.disk"]


def test_response_vectors_decode_with_payload():
    for name, raw in RESPONSES.items():
        if name == "error":
            continue
        payload = protocol.decode_response(raw, request_id=UID, method=name)
        assert isinstance(payload, dict)
    payload = protocol.decode_response(RESPONSES["evaluate"], request_id=UID, method="evaluate")
    assert payload["result"]["decision"]["decision"] == "deny"
    assert payload["via"] == "xpc"
    assert payload["serviceSemver"] == "1.0.0"


def test_wire_request_re_encode_is_byte_exact():
    for name, raw in REQUESTS.items():
        req = protocol.WireRequest.decode(raw)
        rebuilt = protocol.WireRequest(id=req.id, method=req.method, params=req.params)
        assert rebuilt.encode() == raw, f"re-encode drift: {name}"
