# Wire-contract guide

## Boundary checklist

- [ ] Magic/version/type/length are bounded before allocation.
- [ ] Length arithmetic cannot overflow and maximum frame size is enforced.
- [ ] Decoder rejects trailing, missing, duplicate, or unknown fields according to policy.
- [ ] Authentication/authorization occurs before sensitive work.
- [ ] Error categories do not leak secrets or accidental implementation details.
- [ ] Reads and writes handle partial progress and peer closure.
- [ ] Timeout and cancellation close or quarantine the connection consistently.
- [ ] Request IDs, replay/duplication semantics, and ordering are explicit.

Prefer an envelope such as a typed `Message` enum with a versioned payload. Keep transport adapters responsible for bytes and the core responsible for meaning.
