# Phase 2 peer platform proof

This document records API discovery and test scope. It is not a platform certification.

The package deployment floor is macOS 15 (`Package.swift`). The installed SDK public
headers contain all of the primitives below. No private audit-token XPC accessor is used.

| Primitive | Availability evidence | Implemented failure behavior | Runtime proof |
| --- | --- | --- | --- |
| `SecCodeCreateWithXPCMessage` | Public `Security/SecCode.h`; Apple DTS documents macOS 11 introduction | Missing message association or lookup error throws; no PID-only lookup | Fabricated dictionary rejection test; real cross-process XPC success remains required |
| `SecCodeCheckValidity` | Public Security Code Signing Services API predates macOS 15 | Dynamic validity or explicit requirement failure gives no component role | `dynamicCodeInvalidRequirementFailsAndDefaultHasNoRole`; execution result must be recorded by validation owner |
| `SecCodeCopyGuestWithAttributes` with `kSecGuestAttributeAudit` | Public `Security/SecCode.h` | Token-based lookup failure throws; never retries with PID | Real Unix test exercises audit-token guest lookup |
| `getpeereid` | Public Darwin API | Missing UID/GID fails peer capture | Real Unix test exercises accepted and connected sockets |
| `LOCAL_PEERPID` | Public `sys/un.h` at `SOL_LOCAL` | Missing/wrong length/nonpositive PID fails capture | Real Unix test compares kernel PID to test process |
| `LOCAL_PEERTOKEN` | Public `sys/un.h` at `SOL_LOCAL` | Missing/wrong length/inconsistent UID/PID or zero process version fails capture | Real Unix test checks audit-token bytes and signing identity |
| `xpc_connection_set_peer_code_signing_requirement` | Public `xpc/connection.h`, explicitly macOS 12 | Transport integration must treat nonzero configuration result as authentication failure | Not implemented by peer capture helper; transport owner must record integration results |

The real Unix test uses a pathname listener and a real connection, validating both
ends with audit-token lookup. A distinct-process test launches `/usr/bin/nc`, checks its kernel PID and executable
identity, denies it any RV role, and requires recapture to fail after it exits.
Execution outcomes remain unverified until the validation owner records them.
These tests do not simulate wrong-EUID or PID reuse,
FD forwarding, executable replacement, or a successful production/development trust
installation. Those remain separate integration obligations. Tests which cannot run
are not evidence of success.

## Trust installation

`ProtectedPeerTrustConfiguration.installed()` reads only
`/Library/Application Support/RV/peer-trust.json`. The configuration and all ancestors
must be root-owned, with no group/other write access, and no symlinks. Reading uses an
`O_NOFOLLOW` descriptor, `fstat`, and a bounded read. Missing/invalid configuration
must leave the caller with `.denyAll`, never infer trust from same UID or a path name.

The manifest is a JSON array. Each role is one of `cli`, `service`, `workspaceHost`.
Production entries supply `requirement`, `requiredIdentifier`, and
`requiredTeamIdentifier`. Live validation additionally enforces Apple generic anchor,
exact identifier and certificate Team ID, and excludes ad-hoc signatures.

Development entries supply `developmentCDHash`, `developmentExecutablePath` and an
exact requirement of the form `cdhash H"<40 lowercase hex characters>"`. The executable
and all ancestors must also be root-owned and not writable by group/other. The live
peer must have that exact code-directory hash and executable path. This mechanism
is deliberately unusable against a user-writable build directory. No automatic
installation, self-pinning, environment override, or same-user fallback is provided.

A role remains component identity; it does not establish owner authentication or an
Agent Principal. Signed or pinned `rv` must never become a human resolver on that fact.

## Transport caveats

XPC capture uses the `SecCode` derived from the received message, synchronously before
asynchronous dispatch. Connection PID/EUID are diagnostic labels and cannot authorize
an Agent Principal or choose component roles. The message-derived code object decides
component identity. XPC audit-token bytes are not retrieved through private accessors.

The public XPC requirement API checks received messages. Clients must authenticate
an unprivileged handshake response before transmitting permits or other authority
material; merely setting the requirement does not prove outgoing secrecy. A reconnect
must repeat authentication. A transport must also handle peer replacement/disconnect
and bind permits to the authenticated connection.

Unix connection tokens identify the connector. They do not establish who wrote each
later byte after a descriptor transfer. `CLOEXEC` and containment of control descriptors
are necessary, and fresh operation-scoped owner authorization is required where RV
depends on human authority. Component evidence alone cannot solve forwarding.

Primary references:

- [Apple DTS: validating the signature of an XPC process](https://developer.apple.com/forums/thread/681053)
- [Security: SecCodeCopyGuestWithAttributes](https://developer.apple.com/documentation/security/seccodecopyguestwithattributes(_:_:_:_:))

## Executed proofs and final trust restrictions

On macOS 27.0 (26A428), the six targeted Unix/security tests passed, including
kernel audit-token/PID evidence in both directions, a separate `/usr/bin/nc`
peer, dead-peer rejection and an actual extended ACL fixture. The same-process
anonymous XPC request/reply test passed, and captured immutable peer/context state
survived Task dispatch. A real anonymous-endpoint cancellation test passed.
These results do not establish successful installed component-role authentication.

The final trust predicate also requires hardened runtime and rejects DYLD environment
injection, disabled library validation, debugging/get-task-allow, unsigned executable
memory and disabled executable-page-protection entitlements. Role assignment uses
live-hash-bound metadata. An independently compiled ad-hoc executable ran an injected
constructor with an unchanged before/after CDHash; signing that fixture with runtime
hardening suppressed injection. Sources/results are in `phase2/injection-*`.

Configuration/artifact files and every ancestor must have no extended ACL allow
entries (deny-only ACLs are accepted); the opened manifest descriptor is checked too.
This conservative rule may reject otherwise benign read-only ACL allow entries.
Missing configuration never falls back to same-EUID or ad-hoc filename/path trust.

Named Mach XPC is Hello-only discovery. Clients authenticate the endpoint-bearing
reply, create a non-rediscoverable anonymous action connection, authenticate its
Hello, then send action bytes. Interrupted peers are canceled. This addresses
named-service replacement after Hello; full distinct-process product proof remains
outstanding. The client does not send control permits in this incomplete draft.

Deployment minimum remains macOS 15. Headers and target-15 compilation establish
availability, not an executed macOS 15 runtime test. Current-machine proofs do not
certify all supported releases. Public ACL/Security APIs are used; no private SPI.

Primary references:
- [Apple SecCodeCreateWithXPCMessage](https://developer.apple.com/documentation/security/seccodecreatewithxpcmessage(_:_:_:))
- [Apple endpoint lifetime semantics](https://developer.apple.com/documentation/xpc/xpc_connection_create_from_endpoint(_:))
- [Apple LocalAuthentication](https://developer.apple.com/documentation/localauthentication/lacontext)
- [Apple DYLD entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-dyld-environment-variables)
