# Systems-boundary guide

## Descriptor wrapper checklist

- Creation either returns a valid initialized wrapper or closes the partially created handle.
- The wrapper has one logical owner and one close path; duplication is explicit and documented.
- Borrowed reads cannot escape the wrapper or outlive the call.
- `close` is consuming when use after close must be impossible; idempotence is a deliberate contract, not an accident.
- EINTR retry policy is per syscall; do not blindly retry calls whose partial progress or cancellation semantics differ.
- File/socket flags, nonblocking mode, and timeout behavior are tested rather than inferred from one platform.

## Buffer checklist

Validate `count * stride` without overflow, validate alignment and initialized bytes, keep pointers within their permitted closure/lifetime, and return a safe value or `Span` only when the lifetime relationship is expressible. Prefer safe contiguous-storage views over raw pointers when the toolchain supports them.
