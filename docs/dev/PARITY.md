# Parity

Pinned for later tickets. T0 does not implement evaluate.

| Field | Value |
|---|---|
| Upstream | `https://github.com/Dicklesworthstone/destructive_command_guard` |
| Version | **0.11.0** |
| Git tag | `v0.11.0` |
| Tag object | `6d4fcaef45d6b207a291158dc4077e54e6be685c` |
| Commit | `2ed7eeef1ae63d204495f02312c657dd6d9bf73d` |
| v1 scoreboard | Same `Decision` + `rule_id` as the pinned **0.11.0 engine source** (not marketing tables). Critical/high deny; medium/low allow + match. Not line-for-line Rust. Not an alias of the upstream binary. |
| Not a v1 gate | Agree-rate against an upstream CLI on PATH. |

Machine-readable pin: `vendor/parity/PIN`.

Evaluation order (for later tickets, not implemented here): normalize → quick-reject → safe patterns first → destructive → default allow.
