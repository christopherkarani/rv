"""Pending-approval helpers: generation poll and single-use resolve.

``Client.watch_approvals`` and ``Client.pending_resolve`` delegate here.
Resolving echoes the item's id, fingerprint, and identity verbatim; the
service re-verifies all three and resolves terminal-once. Resolving is a
human-attended operation: never auto-allow from an agent loop.
"""

from __future__ import annotations

import time
from collections.abc import Iterator
from typing import TYPE_CHECKING

from . import models
from .errors import Timeout

if TYPE_CHECKING:
    from .client import Client


def poll_batches(
    client: Client,
    *,
    after_generation: int = 0,
    poll_interval: float = 1.0,
    timeout: float | None = None,
) -> Iterator[models.PendingBatch]:
    """Yield a ``PendingBatch`` per changed generation until ``timeout``.

    Each poll is one unary ``pendingWatch`` call; unchanged generations
    return promptly with ``items: []`` and are skipped (only changed
    generations are yielded). ``timeout`` is a total deadline in seconds;
    expiry raises ``Timeout``. Closing the iterator stops polling.
    """
    if poll_interval <= 0:
        raise ValueError("poll_interval must be positive")
    if timeout is not None and timeout < 0:
        raise ValueError("timeout must be non-negative or None")
    deadline = None if timeout is None else time.monotonic() + timeout
    cursor = after_generation
    while True:
        batch = client._pending_watch(cursor)
        if batch.generation != cursor:
            cursor = batch.generation
            yield batch
        if deadline is not None and time.monotonic() >= deadline:
            raise Timeout(f"approval watch exceeded {timeout}s", timeout=timeout)
        time.sleep(poll_interval)


def resolve(
    client: Client,
    item: models.PendingItem,
    allow: bool,
    timeout: float | None = None,
) -> models.ResolveResult:
    """Resolve one approval. ``allow=True`` records a single-use allow-once
    grant; ``allow=False`` denies. Human-attended only."""
    payload = client._call("pendingResolve", models.pending_resolve_wire(item, allow), timeout)
    return models.ResolveResult.from_wire(payload)
