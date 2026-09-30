"""Live integration: real Python SDK through the real wire to a real ``rvd``.

Spawns ``rvd`` (``RV_RVD`` or ``.build/debug/rvd`` or ``.build/release-stage/rvd``,
skipped when absent) in an isolated short ``HOME``/``XDG_RUNTIME_DIR`` and
exercises the curated API end to end. Never touches the developer's real home.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

import pytest

from rv import (
    Client,
    HookHost,
    PackNotFound,
    PendingNotFound,
    RulePolarity,
    Timeout,
    ensure_runtime,
    runtime_status,
)

pytestmark = pytest.mark.integration

REPO_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
)


def _find_rvd() -> str | None:
    override = os.environ.get("RV_RVD")
    if override and os.access(override, os.X_OK):
        return override
    for rel in (".build/debug/rvd", ".build/release-stage/rvd"):
        candidate = os.path.join(REPO_ROOT, rel)
        if os.access(candidate, os.X_OK):
            return candidate
    return None


@pytest.fixture
def live_rvd(monkeypatch):
    if os.name != "posix":
        pytest.skip("integration requires POSIX")
    rvd = _find_rvd()
    if rvd is None:
        pytest.skip("rvd not built (set RV_RVD or run swift build)")
    home = tempfile.mkdtemp(prefix="rvit")
    env = {"HOME": home, "XDG_RUNTIME_DIR": home, "PATH": os.environ.get("PATH", "")}
    proc = subprocess.Popen(
        [rvd, "--idle-exit-seconds", "30"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=env,
    )
    try:
        suffix = ".config/rv/evaluate.sock" if sys.platform == "darwin" else "rv/evaluate.sock"
        sock = os.path.join(home, suffix)
        deadline = time.monotonic() + 10
        while not os.path.exists(sock):
            assert proc.poll() is None, "rvd exited during startup"
            assert time.monotonic() < deadline, "rvd did not bind in time"
            time.sleep(0.05)
        monkeypatch.setenv("RV_RVD", rvd)
        yield {"rvd": rvd, "home": home, "socket": sock}
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=10)
        shutil.rmtree(home, ignore_errors=True)


def test_live_evaluate_deny_and_allow(live_rvd):
    with Client(socket_path=live_rvd["socket"]) as client:
        assert client.service_semver == "1.0.0"
        deny = client.evaluate("git reset --hard", cwd="/tmp")
        assert deny.decision.is_deny
        assert str(deny.decision.deny.rule_id) == "core.git:reset-hard"
        assert deny.analysis.kind == "git"
        allow = client.evaluate("echo hi", cwd="/tmp")
        assert allow.decision.is_allow


def test_live_explain_classify(live_rvd):
    with Client(socket_path=live_rvd["socket"]) as client:
        explanation = client.explain("git reset --hard")
        assert explanation.decision.is_deny
        assert explanation.normalized == "git reset --hard"
        assert str(explanation.rule_id) == "core.git:reset-hard"
        assert explanation.suggestion
        assert len(explanation.stages) >= 1
        classification = client.classify("git reset --hard")
        assert classification.decision.is_deny
        assert classification.risk.safe is False
        assert classification.risk.severity is not None


def test_live_packs_and_doctor(live_rvd):
    with Client(socket_path=live_rvd["socket"]) as client:
        packs = client.list_packs()
        by_id = {pack.id.raw: pack for pack in packs.packs}
        for day_one in ("core.filesystem", "core.git", "system.disk"):
            assert by_id[day_one].enabled is True
            assert by_id[day_one].bundled is True
        assert packs.total_count > 3
        assert packs.enabled_count >= 3
        snapshot = client.doctor()
        assert snapshot.state.value == "running"
        assert snapshot.protocol == "rv.ipc.v1"
        assert snapshot.service_semver == "1.0.0"
        assert len(snapshot.checks) >= 1


def test_live_pending_empty_and_watch_prompt(live_rvd):
    with Client(socket_path=live_rvd["socket"]) as client:
        batch = client.pending_list()
        assert batch.generation == 0
        assert batch.items == ()
        seen = []
        with pytest.raises(Timeout):
            for polled in client.watch_approvals(poll_interval=0.05, timeout=0.3):
                seen.append(polled)
    assert seen == []


def test_live_forged_ids_fail_closed(live_rvd):
    from rv import ApprovalIdentity, PendingItem

    with Client(socket_path=live_rvd["socket"]) as client:
        forged = PendingItem(
            id="forged-does-not-exist",
            host=HookHost.PI,
            folder="ws",
            action_kind="git push",
            fingerprint="shell:forged",
            identity=ApprovalIdentity(session="sess", agent=HookHost.PI),
        )
        with pytest.raises(PendingNotFound):
            client.pending_resolve(forged, allow=True)
        with pytest.raises(PendingNotFound):
            client.rule_preview("forged-does-not-exist", RulePolarity.ALLOW)


def test_live_set_pack_round_trip(live_rvd):
    with Client(socket_path=live_rvd["socket"]) as client:
        disabled = client.set_pack_enabled("core.git", False)
        assert disabled.id.raw == "core.git"
        assert disabled.enabled is False
        enabled = client.set_pack_enabled("core.git", True)
        assert enabled.enabled is True
        with pytest.raises(PackNotFound):
            client.set_pack_enabled("core.nope", True)


def test_live_hook_evaluate_raw_smoke(live_rvd):
    with Client(socket_path=live_rvd["socket"]) as client:
        reply = client.raw.call("hookEvaluate", {"host": "pi", "stdin": ""})
        assert isinstance(reply["exitCode"], int)
        assert isinstance(reply["stdout"], str)
        assert reply["via"] == "xpc"
        assert reply["serviceSemver"] == "1.0.0"


def test_live_ensure_runtime_spawns_and_connects(monkeypatch):
    if os.name != "posix":
        pytest.skip("integration requires POSIX")
    rvd = _find_rvd()
    if rvd is None:
        pytest.skip("rvd not built")
    home = tempfile.mkdtemp(prefix="rven")
    try:
        monkeypatch.setenv("HOME", home)
        monkeypatch.setenv("XDG_RUNTIME_DIR", home)
        monkeypatch.setenv("RV_RVD", rvd)
        path = ensure_runtime(idle_exit_seconds=30)
        assert os.path.exists(path)
        with Client() as client:
            assert client.service_semver == "1.0.0"
            assert client.evaluate("echo hi").decision.is_allow
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_live_runtime_status(live_rvd, monkeypatch):
    monkeypatch.setenv("RV_RVD", live_rvd["rvd"])
    status = runtime_status(socket_path=live_rvd["socket"])
    assert status.ok is True
    assert status.service == "1.0.0"
    assert status.protocol == "rv.ipc.v1"
    assert status.transport == "unix-socket"
    assert status.path == live_rvd["socket"]
    assert status.product is not None
    assert re.match(r"^\d+\.\d+\.\d+", status.product)
