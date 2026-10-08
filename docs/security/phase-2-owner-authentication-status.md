# Phase 2 owner authentication status

Status: BLOCKED for live approval resolution and persistent rule mutation.

The current implementation deliberately rejects pending resolution and rule save before any durable mutation. Historical SessionID/HookHost rows remain readable but cannot deliver an executable allow through the name-only ledger consumption API. Existing command/cwd-only allow-once grants are not created by approval resolution.

`ApprovalSubject` records instance, runtime, workspace, workspace host, host generation, fingerprint, continuation, and trusted policy context. Stored descriptions and decoded subject IDs are not authentication or live validity proof. No existing row is upgraded by guessing its instance.

`ControlAuthorizationBroker` provides an internal service-owned authentication seam. It prompts from the stored row using a fresh `LAContext` with `deviceOwnerAuthentication`, disables biometric reuse, and invalidates the context after the attempt. A receipt binds the complete stored row, resolver owner and connection, requested decision, draft digest where applicable, target policy context, and wall-clock plus monotonic deadlines. Receipt lifetime must be finite and greater than zero, with a five-minute maximum; a wall-clock rollback cannot extend its continuous-clock lifetime. Re-reading the row and validating the authoritative live subject are mandatory both after authentication and during receipt consumption. Consumption removes the receipt before suspension; disconnect invalidates outstanding receipts. A consumed receipt does not itself create an executable grant.

The production dispatch does not install this broker as a working resolver. An authenticated workspace-host channel, current host-backed principal validity, atomic subject-bound resolution/grant storage and principal validation at grant spending are still required. Cached principal descriptions must never satisfy the validation closure. No process can acquire human authority through CLI signing, UID, TTY, or knowledge of approval metadata.

Platform probe reported by the coordinating task: a minimal isolated per-user GUI LaunchAgent invoked LocalAuthentication; its first attempt timed out and a second attempt succeeded. This establishes preliminary deployment feasibility only. The actual integrated RV daemon's exact-operation binding has not been demonstrated. Broker unit tests use an injected authenticator and do not constitute platform proof.

Before enabling mutation, prove the complete actual service path: authenticated peer and permitted control role, stored-row prompt, successful owner authentication, row re-read, authoritative host live validity, atomic compare-and-transition, subject-bound grant, and live revalidation when that grant is consumed. Test revocation, row/draft replacement, host generation change, disconnect, timeout, replay and racing resolvers. Until these are present, Phase 2 cannot be declared complete.
