"""Client, models, raw hatch, approvals, and runtime helpers.

Scripted ``FakeTransport`` drives ``Client`` without a daemon; golden bytes
come from ``test_vectors`` with request ids rewritten per call.
"""

from __future__ import annotations

import json
import os
import shutil
import uuid
from pathlib import Path

import pytest
import test_transports
import test_vectors

from rv import approvals, models, protocol
from rv import client as client_module
from rv.client import Client
from rv.errors import (
    ConnectionFailed,
    CorePacksUnavailable,
    DecodeError,
    MajorVersionSkew,
    PackNotFound,
    PendingIdentityMismatch,
    PendingNotFound,
    ProtocolSkew,
    RuntimeNotFound,
    RuntimeTooOld,
    RvError,
    Timeout,
    UnexpectedResult,
)
from rv.transports import Transport

ACK_OK = b'{"ok":true,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0"}'


class FakeTransport(Transport):
    def __init__(self, script, fail_connect=None):
        self._script = list(script)
        self.fail_connect = fail_connect
        self.received: list[bytes] = []
        self.connected = False
        self.closed = False

    def connect(self, timeout=0.2):
        if self.fail_connect is not None:
            raise self.fail_connect
        self.connected = True

    def close(self):
        self.closed = True
        self.connected = False

    def round_trip(self, body, timeout=0.7):
        if not self.connected:
            raise ConnectionFailed("not connected")
        self.received.append(body)
        item = self._script.pop(0)
        if callable(item):
            return item(json.loads(body))
        return item


def respond(golden: bytes):
    """Reply with golden bytes, rewritten to the request id."""

    def _reply(request: dict) -> bytes:
        obj = json.loads(golden)
        obj["id"] = request["id"]
        return json.dumps(obj).encode()

    return _reply


def respond_error(error: dict):
    def _reply(request: dict) -> bytes:
        return json.dumps(
            {"id": request["id"], "protocol": "rv.ipc.v1", "result": {"error": error}}
        ).encode()

    return _reply


@pytest.fixture(autouse=True)
def _product_ok(monkeypatch):
    monkeypatch.setattr(client_module, "_probe_product", lambda rvd=None: "0.1.5")


def _client(*script, fail_connect=None) -> tuple[Client, FakeTransport]:
    transport = FakeTransport(list(script), fail_connect=fail_connect)
    return Client(transport=transport), transport


# ---------------------------------------------------------------------------
# Connect / handshake.
# ---------------------------------------------------------------------------


def test_connect_sends_hello_and_negotiates():
    client, transport = _client(ACK_OK)
    with client:
        assert client.service_semver == "1.0.0"
    assert transport.closed
    hello = json.loads(transport.received[0])
    assert hello == {"protocol": "rv.ipc.v1", "clientSemver": "1.0.0"}


def test_connect_is_idempotent_and_close_resets():
    client, _ = _client(ACK_OK, ACK_OK)
    client.connect()
    client.connect()
    assert client.service_semver == "1.0.0"
    client.close()
    assert client.service_semver is None


def test_connect_skew_maps_to_typed_errors():
    variants = [
        (
            '{"ok":false,"protocol":"rv.ipc.v1","serviceSemver":"2.0.0",'
            '"skewReason":"major version"}',
            MajorVersionSkew,
        ),
        (
            '{"ok":false,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0","skewReason":"protocol"}',
            ProtocolSkew,
        ),
        (
            '{"ok":false,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0",'
            '"skewReason":"core packs unavailable"}',
            CorePacksUnavailable,
        ),
    ]
    for raw, exc in variants:
        client, _ = _client(raw.encode())
        with pytest.raises(exc):
            client.connect()


def test_connect_protocol_mismatch_and_bad_versions():
    client, _ = _client(b'{"ok":true,"protocol":"rv.ipc.v0","serviceSemver":"1.0.0"}')
    with pytest.raises(ProtocolSkew):
        client.connect()
    for bad in ("garbage", ""):
        raw = json.dumps({"ok": True, "protocol": "rv.ipc.v1", "serviceSemver": bad}).encode()
        client, _ = _client(raw)
        with pytest.raises(MajorVersionSkew):
            client.connect()
    raw = json.dumps({"ok": True, "protocol": "rv.ipc.v1"}).encode()
    client, _ = _client(raw)
    with pytest.raises(DecodeError):
        client.connect()


def test_connect_enforces_product_floor(monkeypatch):
    monkeypatch.setattr(client_module, "_probe_product", lambda rvd=None: None)
    client, _ = _client(ACK_OK)
    with pytest.raises(RuntimeNotFound) as info:
        client.connect()
    assert "PATH" in str(info.value)
    monkeypatch.setattr(client_module, "_probe_product", lambda rvd=None: "0.1.4")
    client, _ = _client(ACK_OK)
    with pytest.raises(RuntimeTooOld) as info:
        client.connect()
    assert info.value.found == "0.1.4"


def test_call_without_connect_fails():
    client, _ = _client()
    with pytest.raises(ConnectionFailed):
        client.list_packs()


# ---------------------------------------------------------------------------
# Curated operations against goldens.
# ---------------------------------------------------------------------------


def _connected(*script) -> tuple[Client, FakeTransport]:
    client, transport = _client(ACK_OK, *script)
    client.connect()
    assert len(transport.received) == 1
    return client, transport


def test_evaluate_deny_golden():
    client, transport = _connected(respond(test_vectors.RESPONSES["evaluate"]))
    result = client.evaluate("git reset --hard", cwd="/repo")
    assert result.decision.is_deny
    assert str(result.decision.deny.rule_id) == "core.git:reset-hard"
    assert result.outcome is models.OutcomeKind.DENY
    assert result.matching_view == ""
    assert result.analysis.kind == "unknown"
    params = json.loads(transport.received[1])["method"]["evaluate"]
    assert params["request"]["command"] == "git reset --hard"
    assert params["request"]["enabledPacks"] == ["core.filesystem", "core.git", "system.disk"]
    assert params["cwd"] == "/repo"
    assert params["clientSemver"] == "1.0.0"


def test_evaluate_via_and_reply_skew_enforced():
    mutated = json.loads(test_vectors.RESPONSES["evaluate"])
    mutated["result"]["evaluate"]["via"] = "inProcess"
    client, _ = _connected(lambda req: _with_id(mutated, req))
    with pytest.raises(DecodeError):
        client.evaluate("x")
    mutated = json.loads(test_vectors.RESPONSES["evaluate"])
    mutated["result"]["evaluate"]["serviceSemver"] = "2.0.0"
    client, _ = _connected(lambda req: _with_id(mutated, req))
    with pytest.raises(MajorVersionSkew):
        client.evaluate("x")


def _with_id(obj: dict, request: dict) -> bytes:
    obj["id"] = request["id"]
    return json.dumps(obj).encode()


def test_explain_derives_ids_and_stages():
    client, _ = _connected(respond(test_vectors.RESPONSES["explain"]))
    explanation = client.explain("git reset --hard")
    assert explanation.decision.is_deny
    assert str(explanation.rule_id) == "core.git:reset-hard"
    assert str(explanation.pack_id) == "core.git"
    assert explanation.normalized == "git reset --hard"
    assert explanation.suggestion == "Run it in Terminal, or rv allow-once."
    assert [s.name for s in explanation.stages] == [models.ExplainStageName.NORMALIZE]
    assert explanation.stages[0].elapsed_ms == 0.1


def test_explain_ignores_sibling_ids():
    mutated = json.loads(test_vectors.RESPONSES["explain"])
    mutated["result"]["explain"]["ruleID"] = "core.git:other"
    mutated["result"]["explain"]["packID"] = "core.git"
    client, _ = _connected(lambda req: _with_id(mutated, req))
    explanation = client.explain("git reset --hard")
    # Derived from the outcome, never trusted from siblings.
    assert str(explanation.rule_id) == "core.git:reset-hard"


def test_classify_risk_reasons_suggestions():
    client, _ = _connected(respond(test_vectors.RESPONSES["classify"]))
    classification = client.classify("git reset --hard")
    assert classification.decision.is_deny
    assert classification.risk.safe is False
    assert classification.risk.severity is models.Severity.HIGH
    assert str(classification.rule_id) == "core.git:reset-hard"
    assert classification.reasons == ()
    assert classification.suggestions == ()


def test_packs_round_trip():
    client, transport = _connected(
        respond(test_vectors.RESPONSES["listPacks"]),
        respond(test_vectors.RESPONSES["setPackEnabled"]),
    )
    packs = client.list_packs()
    assert packs.enabled_count == 1
    assert packs.total_count == 1
    assert packs.packs[0].id.raw == "core.git"
    assert packs.packs[0].enabled is True
    updated = client.set_pack_enabled("core.git", False)
    assert updated.enabled is False
    params = json.loads(transport.received[2])["method"]["setPackEnabled"]
    assert params == {"id": "core.git", "enabled": False}


def test_doctor_snapshot():
    client, _ = _connected(respond(test_vectors.RESPONSES["doctorSnapshot"]))
    snapshot = client.doctor()
    assert snapshot.service_semver == "1.0.0"
    assert snapshot.state is models.ServiceState.RUNNING
    assert snapshot.keep_alive is False
    assert snapshot.idle_exit_seconds == 300
    assert [p.raw for p in snapshot.packs_enabled] == ["core.git"]
    assert snapshot.checks[0].id == "xpc"
    assert snapshot.checks[0].status is models.DoctorCheckStatus.OK


def test_doctor_tolerates_unknown_check_id():
    mutated = json.loads(test_vectors.RESPONSES["doctorSnapshot"])
    mutated["result"]["doctorSnapshot"]["checks"].append(
        {"id": "future-check", "status": "ok", "message": "new"}
    )
    client, _ = _connected(lambda req: _with_id(mutated, req))
    snapshot = client.doctor()
    assert snapshot.checks[-1].id == "future-check"


def test_pending_list_items():
    client, _ = _connected(respond(test_vectors.RESPONSES["pendingList"]))
    batch = client.pending_list()
    assert batch.generation == 1
    (item,) = batch.items
    assert item.id == "ask-1"
    assert item.host is models.HookHost.PI
    assert item.folder == "ws"
    assert item.action_kind == "git push"
    assert item.fingerprint == "shell:git"
    assert item.identity.session == "sess"
    assert item.identity.agent is models.HookHost.PI
    assert item.session_suffix is None


def _watch_reply(generation: int, items: list):
    def _reply(request: dict) -> bytes:
        return json.dumps(
            {
                "id": request["id"],
                "protocol": "rv.ipc.v1",
                "result": {"pendingWatch": {"generation": generation, "items": items}},
            }
        ).encode()

    return _reply


def test_watch_approvals_skips_unchanged_and_yields_changes():
    item = json.loads(test_vectors.RESPONSES["pendingList"])["result"]["pendingList"]["items"][0]
    client, _ = _connected(
        _watch_reply(5, []),
        _watch_reply(5, []),
        _watch_reply(6, [item]),
    )
    batches = []
    for batch in client.watch_approvals(after_generation=5, poll_interval=0.01, timeout=5):
        batches.append(batch)
        break
    assert [b.generation for b in batches] == [6]
    assert batches[0].items[0].id == "ask-1"


def test_watch_approvals_timeout_and_validation():
    client, _ = _connected(*[_watch_reply(5, []) for _ in range(30)])
    with pytest.raises(Timeout):
        for _ in client.watch_approvals(after_generation=5, poll_interval=0.01, timeout=0.05):
            pass
    with pytest.raises(ValueError):
        next(client.watch_approvals(poll_interval=0))
    with pytest.raises(ValueError):
        next(client.watch_approvals(timeout=-1))


def test_pending_resolve_echoes_item():
    client, transport = _connected(
        respond(test_vectors.RESPONSES["pendingList"]),
        respond(test_vectors.RESPONSES["pendingResolve"]),
    )
    (item,) = client.pending_list().items
    result = client.pending_resolve(item, allow=True)
    assert result.id == "ask-1"
    assert result.terminal is True
    params = json.loads(transport.received[2])["method"]["pendingResolve"]
    assert params == {
        "id": "ask-1",
        "decision": "allowOnce",
        "fingerprint": "shell:git",
        "identity": {"agent": "pi", "session": "sess"},
    }


def test_rule_preview_and_save():
    client, transport = _connected(
        respond(test_vectors.RESPONSES["rulePreview"]),
        respond(test_vectors.RESPONSES["ruleSave"]),
    )
    draft = client.rule_preview("ask-1", models.RulePolarity.ALLOW)
    assert draft.allowed_to_save is True
    assert draft.draft == "opaque-draft"
    saved = client.rule_save("ask-1", models.RulePolarity.BLOCK, draft.draft)
    assert str(saved.rule_id) == "core.git:reset-hard"
    assert saved.wait_resolved is True
    params = json.loads(transport.received[2])["method"]["ruleSave"]
    assert params["draft"] == "opaque-draft"


def test_error_results_raise_typed():
    client, _ = _connected(respond_error({"pendingNotFound": True}))
    with pytest.raises(PendingNotFound):
        client.pending_list()
    client, _ = _connected(respond_error({"protocolSkew": "major version"}))
    with pytest.raises(MajorVersionSkew):
        client.list_packs()
    client, _ = _connected(respond_error({"packNotFound": "core.nope"}))
    with pytest.raises(PackNotFound) as info:
        client.list_packs()
    assert info.value.pack_id == "core.nope"


def test_echo_mismatch_raises():
    def _wrong_id(request: dict) -> bytes:
        obj = json.loads(test_vectors.RESPONSES["listPacks"])
        obj["id"] = str(uuid.uuid4()).upper()
        return json.dumps(obj).encode()

    client, _ = _connected(_wrong_id)
    with pytest.raises(UnexpectedResult):
        client.list_packs()


def test_wrong_variant_raises():
    client, _ = _connected(respond(test_vectors.RESPONSES["doctorSnapshot"]))
    with pytest.raises(UnexpectedResult):
        client.list_packs()


# ---------------------------------------------------------------------------
# Raw hatch.
# ---------------------------------------------------------------------------


def test_raw_returns_verbatim_dicts():
    client, transport = _connected(respond(test_vectors.RESPONSES["doctorSnapshot"]))
    payload = client.raw.call("doctorSnapshot", {})
    assert payload["label"] == "dev.rv.evaluate"
    assert json.loads(transport.received[1])["method"] == {"doctorSnapshot": {}}


def test_raw_validates_method_and_params():
    client, _ = _connected()
    with pytest.raises(ValueError):
        client.raw.call("nope", {})
    with pytest.raises(ValueError):
        client.raw.call("listPacks", ["x"])  # type: ignore[arg-type]


def test_raw_applies_echo_error_and_skew_gates():
    client, _ = _connected(respond_error({"pendingIdentityMismatch": True}))
    with pytest.raises(PendingIdentityMismatch):
        client.raw.call("pendingList", {})
    mutated = json.loads(test_vectors.RESPONSES["evaluate"])
    mutated["result"]["evaluate"]["serviceSemver"] = "9.9.9"
    client, _ = _connected(lambda req: _with_id(mutated, req))
    with pytest.raises(MajorVersionSkew):
        client.raw.call("evaluate", {"request": {"command": "x", "enabledPacks": []}})


# ---------------------------------------------------------------------------
# Models: identifiers, validation, outcome algebra.
# ---------------------------------------------------------------------------


def test_pack_id_grammar():
    for raw in ["core.git", "a", "ab1_", "a.b", "system.disk"]:
        assert models.PackID(raw).raw == raw
    for raw in ["", "a.b.c", "Core.git", ".git", "core.", "0a", "a..b", "a:b", "a b", "Ä"]:
        with pytest.raises(ValueError):
            models.PackID(raw)


def test_rule_id_parse():
    rule = models.RuleID.parse("core.git:reset-hard")
    assert rule.pack.raw == "core.git"
    assert rule.pattern == "reset-hard"
    assert rule.raw == "core.git:reset-hard"
    assert str(rule) == "core.git:reset-hard"
    # Patterns may contain further colons (split on the FIRST).
    assert models.RuleID.parse("a:b:c").pattern == "b:c"
    for raw in ["nocolon", ":x", "x:", "", "Bad:x", "a:b:c:d:e"]:
        if raw == "a:b:c:d:e":
            assert models.RuleID.parse(raw).pattern == "b:c:d:e"
            continue
        with pytest.raises(ValueError):
            models.RuleID.parse(raw)


def test_coerce_packs_and_cwd():
    assert models.coerce_packs(None) == ["core.filesystem", "core.git", "system.disk"]
    assert models.coerce_packs(["core.git", models.PackID("core.filesystem")]) == [
        "core.git",
        "core.filesystem",
    ]
    with pytest.raises(ValueError):
        models.coerce_packs("core.git")
    with pytest.raises(ValueError):
        models.coerce_packs(["Bogus"])
    with pytest.raises(ValueError):
        models.coerce_packs([42])
    assert models.coerce_cwd(None) is None
    assert models.coerce_cwd("/repo") == "/repo"
    assert models.coerce_cwd(Path("/repo")) == "/repo"
    with pytest.raises(ValueError):
        models.coerce_cwd("")


def _evaluation_result(decision, **overrides):
    base: dict = {"decision": decision}
    base.update(overrides)
    return base


def test_evaluation_outcome_algebra():
    allow = {"decision": "allow"}
    assert models.Evaluation.from_wire(_evaluation_result(allow)).outcome is (
        models.OutcomeKind.PLAIN
    )
    assert (
        models.Evaluation.from_wire(_evaluation_result(allow, quickRejected=True)).outcome
        is models.OutcomeKind.QUICK_REJECTED
    )
    safe = {"packID": "core.git", "patternName": "p"}
    assert (
        models.Evaluation.from_wire(_evaluation_result(allow, matchedSafe=safe)).outcome
        is models.OutcomeKind.SAFE_ONLY
    )
    matched = {
        "ruleID": "core.git:r",
        "severity": "high",
        "reason": "x",
    }
    assert (
        models.Evaluation.from_wire(_evaluation_result(allow, matched=matched)).outcome
        is models.OutcomeKind.HIT
    )
    deny = {"decision": "deny", "ruleID": "core.git:r", "reason": "x"}
    assert models.Evaluation.from_wire(_evaluation_result(deny)).outcome is (
        models.OutcomeKind.DENY
    )
    indet = {"decision": "indeterminate", "indeterminateReason": "budgetExhausted"}
    assert models.Evaluation.from_wire(_evaluation_result(indet)).outcome is (
        models.OutcomeKind.INDETERMINATE
    )


def test_evaluation_impossible_combos_fail_closed():
    allow = {"decision": "allow"}
    matched = {"ruleID": "core.git:r", "severity": "high", "reason": "x"}
    safe = {"packID": "core.git", "patternName": "p"}
    with pytest.raises(DecodeError):
        models.Evaluation.from_wire(_evaluation_result(allow, quickRejected=True, matched=matched))
    with pytest.raises(DecodeError):
        models.Evaluation.from_wire(
            _evaluation_result(
                {"decision": "deny", "ruleID": "core.git:r", "reason": "x"}, matchedSafe=safe
            )
        )
    with pytest.raises(DecodeError):
        models.Evaluation.from_wire(
            _evaluation_result(
                {"decision": "deny", "ruleID": "core.git:r", "reason": "x"}, quickRejected=True
            )
        )
    with pytest.raises(DecodeError):
        models.Evaluation.from_wire(
            _evaluation_result(
                {"decision": "indeterminate", "indeterminateReason": "budgetExhausted"},
                matched=matched,
            )
        )


def test_decision_leftover_ask_is_deny():
    decision = models.Decision.from_wire({"decision": "ask"})
    assert decision.is_deny
    assert decision.deny is not None
    assert str(decision.deny.rule_id) == "builtin.action:leftover-ask"
    assert decision.deny.reason == "Ask is not a permit."
    with pytest.raises(DecodeError):
        models.Decision.from_wire({"decision": "maybe"})
    assert str(models.Decision.from_wire({"decision": "allow"})) == "allow"


def test_rule_match_echo_must_match():
    good = {"ruleID": "core.git:r", "severity": "high", "reason": "x"}
    assert models.RuleMatch.from_wire(good).pack_id.raw == "core.git"
    with_echo = dict(good, packID="core.git", patternName="r")
    assert models.RuleMatch.from_wire(with_echo).pattern_name == "r"
    with pytest.raises(DecodeError):
        models.RuleMatch.from_wire(dict(good, packID="core.other"))
    with pytest.raises(DecodeError):
        models.RuleMatch.from_wire(dict(good, patternName="other"))
    with pytest.raises(DecodeError):
        models.RuleMatch.from_wire(dict(good, severity="extreme"))
    span = models.RuleMatch.from_wire(dict(good, span={"start": 1, "end": 3}))
    assert span.span == (1, 3)
    with pytest.raises(DecodeError):
        models.RuleMatch.from_wire(dict(good, span={"start": 1}))


def test_classify_allow_adopts_and_validates_siblings():
    base: dict = {
        "decision": {"decision": "allow"},
        "risk": "safe",
        "ruleID": "core.git:r",
        "packID": "core.git",
    }
    classification = models.Classification.from_wire(base)
    assert classification.risk.safe is True
    assert str(classification.rule_id) == "core.git:r"
    assert str(classification.pack_id) == "core.git"
    bad = dict(base, packID="core.other")
    with pytest.raises(DecodeError):
        models.Classification.from_wire(bad)
    pack_only = {"decision": {"decision": "allow"}, "risk": "safe", "packID": "core.git"}
    classification = models.Classification.from_wire(pack_only)
    assert classification.rule_id is None
    assert classification.pack_id is not None
    with pytest.raises(DecodeError):
        models.Classification.from_wire({"decision": {"decision": "allow"}, "risk": "mild"})


def test_analysis_wrapper_derivation_and_opaque_future_case():
    wrapped = {"wrapper": {"_0": "bash", "inner": {"git": {"_0": {"reset": {"mode": "hard"}}}}}}
    analysis = models.Analysis.from_wire(wrapped)
    assert analysis.kind == "wrapper"
    assert analysis.wrappers == ("bash",)
    assert analysis.innermost_kind == "git"
    assert analysis.raw == wrapped["wrapper"]
    future = {"network": {"egress": True}}
    analysis = models.Analysis.from_wire(future)
    assert analysis.kind == "network"
    assert analysis.raw == {"egress": True}
    with pytest.raises(DecodeError):
        models.Analysis.from_wire({"a": 1, "b": 2})


def test_approval_identity_requires_nonempty_session():
    with pytest.raises(ValueError):
        models.ApprovalIdentity(session="", agent=models.HookHost.PI)
    with pytest.raises(DecodeError):
        models.ApprovalIdentity.from_wire({"session": "", "agent": "pi"})
    with pytest.raises(DecodeError):
        models.ApprovalIdentity.from_wire({"session": "s", "agent": "unknown-host"})
    identity = models.ApprovalIdentity.from_wire({"session": "s", "agent": "pi"})
    assert identity.to_wire() == {"session": "s", "agent": "pi"}


# ---------------------------------------------------------------------------
# Coverage drift + error exhaustiveness.
# ---------------------------------------------------------------------------


def test_method_coverage_is_total():
    assert set(protocol.METHODS) == set(client_module.CURATED_METHODS) | set(
        client_module.RAW_ONLY_METHODS
    )
    assert client_module.RAW_ONLY_METHODS == frozenset({"hookEvaluate"})
    curated = {
        "evaluate": "evaluate",
        "explain": "explain",
        "classify": "classify",
        "listPacks": "list_packs",
        "setPackEnabled": "set_pack_enabled",
        "doctorSnapshot": "doctor",
        "pendingList": "pending_list",
        "pendingWatch": "watch_approvals",
        "pendingResolve": "pending_resolve",
        "rulePreview": "rule_preview",
        "ruleSave": "rule_save",
    }
    assert set(curated) == set(client_module.CURATED_METHODS)
    for attribute in curated.values():
        assert callable(getattr(Client, attribute)), attribute
    assert not hasattr(Client, "hook_evaluate")


def test_ipc_error_kinds_all_map_to_rv_errors():
    from rv.errors import IPCErrorValue, raise_for_ipc_error

    kinds = [
        ("unknownMethod", None),
        ("decodeFailed", None),
        ("protocolSkew", "major version"),
        ("hookEvaluateFailed", None),
        ("packEnableFailed", None),
        ("rulePinRequiresMatchingView", None),
        ("pendingAllowOnceNotUnlockable", None),
        ("pendingCoordinatorUnavailable", None),
        ("engine", "leftover sentence"),
        ("packNotFound", "core.git"),
        ("allowOnceNotFound", None),
        ("allowOnceAlreadyConsumed", None),
        ("allowOnceExpired", None),
        ("pendingNotFound", None),
        ("pendingAlreadyTerminal", None),
        ("pendingIdentityMismatch", None),
        ("pendingFingerprintMismatch", None),
        ("ruleDraftMismatch", None),
        ("ruleHardStop", None),
    ]
    assert len(kinds) == 19
    for kind, payload in kinds:
        with pytest.raises(RvError):
            raise_for_ipc_error(IPCErrorValue(kind, payload))


# ---------------------------------------------------------------------------
# Module one-shots and runtime helpers.
# ---------------------------------------------------------------------------


def test_module_one_shots_use_client(monkeypatch):
    calls = []

    class StubClient:
        def __init__(self, socket_path=None):
            calls.append(socket_path)

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return None

        def evaluate(self, command, cwd=None, packs=None, budget=None):
            calls.append(("evaluate", command, cwd))
            return "EVAL"

    monkeypatch.setattr(client_module, "Client", StubClient)
    assert client_module.evaluate("ls", cwd="/r", socket_path="/tmp/s.sock") == "EVAL"
    assert calls == ["/tmp/s.sock", ("evaluate", "ls", "/r")]


def test_runtime_status_ok_and_failure(monkeypatch):
    # OK path via a fake Client.
    class OkClient:
        def __init__(self, socket_path=None):
            self.socket_path = socket_path

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return None

        @property
        def service_semver(self):
            return "1.0.0"

    monkeypatch.setattr(client_module, "Client", OkClient)
    monkeypatch.setattr(client_module.transports, "resolve_socket_path", lambda p=None: "/s.sock")
    status = client_module.runtime_status(socket_path="/s.sock")
    assert status.ok is True
    assert status.service == "1.0.0"
    assert status.product == "0.1.5"
    assert status.transport == "unix-socket"

    class DownClient:
        def __init__(self, socket_path=None):
            pass

        def __enter__(self):
            raise ConnectionFailed("down")

        def __exit__(self, *exc):
            return None

    monkeypatch.setattr(client_module, "Client", DownClient)
    status = client_module.runtime_status()
    assert status.ok is False
    assert status.error == "down"


def test_ensure_runtime_returns_existing_without_spawning(monkeypatch):
    short = f"/tmp/rv-ensure-{os.getpid()}"
    inner = short + "/in"
    os.makedirs(inner, exist_ok=True)
    os.chmod(short, 0o700)
    os.chmod(inner, 0o700)
    path = inner + "/t.sock"
    try:
        with test_transports.FakeServer(path, []):
            monkeypatch.setattr(client_module.shutil, "which", lambda name: None)
            assert client_module.ensure_runtime(socket_path=path) == path
    finally:
        shutil.rmtree(short, ignore_errors=True)


def test_ensure_runtime_missing_binary_raises(monkeypatch):
    monkeypatch.setattr(client_module.shutil, "which", lambda name: None)
    monkeypatch.delenv("RV_RVD", raising=False)
    # Fake bases on both platforms so a live dev daemon can't satisfy the probe.
    monkeypatch.setenv("HOME", f"/tmp/rv-eh-{os.getpid()}")
    monkeypatch.setenv("XDG_RUNTIME_DIR", f"/tmp/rv-ex-{os.getpid()}")
    with pytest.raises(RuntimeNotFound) as info:
        client_module.ensure_runtime()
    assert "PATH" in str(info.value)


def test_ensure_runtime_explicit_path_never_spawns(monkeypatch):
    monkeypatch.setattr(client_module.shutil, "which", lambda name: "/bin/false")
    with pytest.raises(RuntimeNotFound) as info:
        client_module.ensure_runtime(socket_path=f"/tmp/rv-ensure-missing-{os.getpid()}/x.sock")
    assert "production path only" in str(info.value)


def test_runtime_status_missing_is_typed():
    status = client_module.runtime_status(socket_path=f"/tmp/rv-it-missing-{os.getpid()}/x.sock")
    assert status.ok is False
    assert status.error


def test_approvals_validation():
    client, _ = _connected()
    with pytest.raises(ValueError):
        next(approvals.poll_batches(client, poll_interval=0))
    with pytest.raises(ValueError):
        models.pending_resolve_wire("not-an-item", True)  # type: ignore[arg-type]
    with pytest.raises(ValueError):
        models.pending_watch_wire(-1)
    with pytest.raises(ValueError):
        models.rule_preview_wire("", models.RulePolarity.ALLOW)
    with pytest.raises(ValueError):
        models.rule_preview_wire("a", "allow")  # type: ignore[arg-type]
