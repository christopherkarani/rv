"""Shared fixtures for the rv-sdk test suite."""

from __future__ import annotations

import os
import shutil
import tempfile

import pytest

from rv import client as client_module


@pytest.fixture
def _product_ok(monkeypatch):
    # Unit tests drive Client with scripted transports (no rvd on PATH),
    # so pin the product probe. Opt-in per module via usefixtures: live
    # integration tests must exercise the real probe.
    monkeypatch.setattr(client_module, "_probe_product", lambda rvd=None: "0.1.5")


@pytest.fixture
def socket_path():
    # /tmp-rooted with 0700 parents: pytest tmp paths overflow the Darwin
    # 104-byte sockaddr_un cap.
    root = tempfile.mkdtemp(prefix="rvt")
    inner = os.path.join(root, "in")
    os.mkdir(inner)
    os.chmod(root, 0o700)
    os.chmod(inner, 0o700)
    yield os.path.join(inner, "t.sock")
    shutil.rmtree(root, ignore_errors=True)
