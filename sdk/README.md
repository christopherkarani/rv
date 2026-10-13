# RV SDKs

All SDK surface for RV, all languages. Swift stays in `Sources/`; this directory
holds the language-neutral contracts plus one distribution root per SDK language.

```text
sdk/
├── README.md        # this index
├── WIRE.md          # normative rv.ipc.v1 wire contract (JSON shapes, framing, handshake, errors)
├── VERSIONING.md    # normative version-negotiation policy
└── python/          # Python SDK distribution root (pip install ./sdk/python)
```

Future languages land as siblings (`sdk/typescript/`, `sdk/go/`, `sdk/rust/`)
built against `sdk/WIRE.md` — no new top-level directories, no `proto/`
toolchain, no per-language wire.

## Trust model

SDKs express intent. RV establishes identity, determines authority, and enforces
the decision — all in Swift. An SDK must never implement, cache, pre-evaluate,
or short-circuit policy decisions, ALLOW/ASK/DENY semantics, principal or agent
verification, sandbox construction, shell/network admission, secret release, MCP
authorization, or human-approval resolution. Skew or an unreachable service is a
hard typed error, never a local verdict (`sdk/VERSIONING.md` §4).

## Transport support

| SDK operation set | Linux | macOS |
|---|---|---|
| `rv.ipc.v1` (evaluate/explain/classify/packs/doctor/pending/rules) | AF_UNIX `$XDG_RUNTIME_DIR/rv/evaluate.sock` | AF_UNIX `$HOME/.config/rv/evaluate.sock` |
| XPC Mach service `dev.rv.evaluate` | n/a | Swift/C only (hook hot path) |
| `rv.workspace.v1` (terminal attach, PTY) | n/a | Swift CLI only in v1 |

See `sdk/WIRE.md` §1 for resolution, modes, caps, and timeouts.

## Install model

SDK and runtime are separate products with separate installs. An SDK wheel must
not contain, download, compile, or vendor Swift/C binaries, pack bundles, or
dylibs. It connects to an existing RV runtime installed via `install.sh` or
GitHub releases; a missing runtime is a typed error with remediation, never a
silent download or implicit daemon spawn.

## Versioning

Four lines — SDK release, RV product, protocol name, service semver — plus
additive capability tokens. Full policy in `sdk/VERSIONING.md`.
