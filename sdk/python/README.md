# rv-sdk — Python SDK for RV

Intent-only Python client for the local RV policy service (`rvd`). Evaluate shell
commands against policy, explain verdicts, review human approvals, and pin rules —
with every security decision made by the Swift service, never by this package.

```python
from rv import Client

with Client() as client:
    result = client.evaluate("git reset --hard", cwd="/repo")
    print(result.decision)  # deny(...)
```

## Install

The SDK and the RV runtime are separate installs. Install the runtime once:

```bash
curl -fsSL https://rykanv.com/install | sh
```

Then install the pure-Python wheel (zero runtime dependencies):

```bash
pip install rv-sdk
```

Check the pairing:

```bash
python -c "import rv; print(rv.runtime_status())"
```

`rv.runtime_status()` reports the runtime path and product version (via
`rvd --version`), transport reachability (Hello round-trip), protocol/service
versions, and the minimum-floor check. A missing runtime is a typed error naming
the missing piece and the fix — the SDK never downloads, bundles, or implicitly
starts anything. `rv.ensure_runtime()` explicitly spawns a supervised `rvd` when
you ask it to (useful in containers without user units); it is never implicit.

Requires Python 3.10+, macOS 15+ (arm64) or Linux (aarch64/x86_64), and an
installed RV runtime ≥ 0.1.5 speaking `rv.ipc.v1`.

## What the SDK is (and is not)

- The SDK **expresses intent**: typed `evaluate` / `explain` / `classify` /
  packs / doctor / pending / rule calls over a versioned JSON protocol
  (`sdk/WIRE.md`). All policy, authorization, admission, sandboxing, and approval
  decisions stay in Swift.
- The SDK has **no offline mode**: an unreachable or version-skewed service is a
  hard typed error, never a locally computed verdict (`sdk/VERSIONING.md` §4).
- The API is **sync-only** in v1. Approval watching is a blocking iterator over
  the service's generation poll; per-call timeouts (700 ms default, configurable)
  plus iterator `close()` cover cancellation.
- Sensitive operations are gated by construction: `pending_resolve` only resolves
  items obtained from the approvals iterator (fingerprint + identity echo);
  `rule_save` only persists drafts from `rule_preview`; `set_pack_enabled` is
  operator-only. There are no session/exec/PTY, secrets, MCP, or supervisor APIs
  in v1 — RV exposes none of those over this boundary.

## Layout

```text
src/rv/
├── __init__.py    # public API re-exports + __version__ (single source)
├── client.py      # Client: connect, Hello, call dispatch, close
├── raw.py         # raw.call(method, params): untyped forward-compat hatch
├── transports.py  # UnixSocketTransport: resolution, mode checks, budgets
├── protocol.py    # Hello/HelloAck/IPCRequest/IPCResponse/IPCError wire codec
├── frames.py      # FrameCodec port (4-byte big-endian, 1 MiB cap, ordered errors)
├── versions.py    # semver-major port, skew checks, MIN_* floors
├── errors.py      # exception hierarchy (mirrors IPCError 1:1)
├── models.py      # frozen curated dataclasses + outcome algebra
└── approvals.py   # pending/ASK helpers (poll iterator, single-use resolve)
tests/
├── test_frames.py       # FrameCodec vectors (shared bytes with Swift goldens)
├── test_versions.py     # semver-major port, skew checks, product floors
├── test_protocol.py     # handshake/skew/unknown-key tolerance/strict-enum tests
├── test_vectors.py      # shared golden bytes (same literals as SDKVectorTests)
├── test_transports.py   # resolution, mode checks, scripted fake server
├── test_client.py       # public API, conversion, exceptions, mocked transports
├── test_integration.py  # real rvd over a real socket (marked, CI-gated)
└── test_security.py     # fail-closed regression tests
```

Wire notes that shaped this layout: there are no `Date` values on `rv.ipc.v1`
(so no date codec), UUIDs emit uppercase but parse any case, and `exitCode` is a
plain int. The macOS SDK socket (`$HOME/.config/rv/evaluate.sock`, served by
`rvd` alongside XPC) means both platforms share one transport — there is no
subprocess fallback and no subprocess transport module.

## Development

```bash
cd sdk/python
python -m venv .venv && source .venv/bin/activate
pip install -e ".[test]" ruff
pytest tests -m "not integration"
ruff check src tests && ruff format --check src tests
RV_RVD=/path/to/rvd pytest tests -m integration  # needs a built rvd
```

Wire changes require a version decision: see `sdk/WIRE.md` §8 and
`sdk/VERSIONING.md` before touching `protocol.py`, `frames.py`, or `versions.py`.
