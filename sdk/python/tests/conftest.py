"""Shared fixtures for the rv-sdk test suite."""

from __future__ import annotations

import os
import shutil
import tempfile

import pytest


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
